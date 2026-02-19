#!/usr/bin/env bash
# Mission Control v0.3 — Coordination layer for OpenClaw agent fleets
# Zero dependencies beyond bash + sqlite3
# Supports projects (physical DB isolation) and multi-mission (logical isolation)
set -euo pipefail

AGENT="${MC_AGENT:-$(whoami)}"
SCHEMA_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")" && pwd)"
PROFILE="${OPENCLAW_PROFILE:-}"
if [ -n "$PROFILE" ]; then
  CONFIG_DIR="$HOME/.openclaw-$PROFILE"
else
  CONFIG_DIR="$HOME/.openclaw"
fi

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

# ═══════════════════════════════════════════
# GLOBAL FLAG PARSING (before subcommand)
# ═══════════════════════════════════════════

PROJECT_FLAG=""
MISSION_FLAG=""
ARGS=()

# Only parse global flags BEFORE the subcommand (first non-flag argument)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project|-w|--workspace) PROJECT_FLAG="$2"; shift 2;;
    -m|--mission)   MISSION_FLAG="$2"; shift 2;;
    -*) ARGS+=("$1"); shift;;   # unknown flag before subcommand
    *)  break;;                  # subcommand found — stop global parsing
  esac
done

# Remaining args = subcommand + its arguments
ARGS+=("$@")
set -- "${ARGS[@]+"${ARGS[@]}"}"

# ═══════════════════════════════════════════
# PROJECT & MISSION RESOLUTION
# ═══════════════════════════════════════════

resolve_project() {
  if [ -n "$PROJECT_FLAG" ]; then echo "$PROJECT_FLAG"; return; fi
  if [ -n "${MC_PROJECT:-}" ]; then echo "$MC_PROJECT"; return; fi
  if [ -n "${MC_WORKSPACE:-}" ]; then echo "$MC_WORKSPACE"; return; fi
  if [ -f ".mc-workspace" ]; then cat .mc-workspace; return; fi
  if [ -f "$CONFIG_DIR/config.json" ]; then
    local val
    val=$(grep -o '"default_project":"[^"]*"' "$CONFIG_DIR/config.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [ -n "$val" ]; then echo "$val"; return; fi
    # Fallback: legacy key
    val=$(grep -o '"default_workspace":"[^"]*"' "$CONFIG_DIR/config.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [ -n "$val" ]; then echo "$val"; return; fi
  fi
  echo "default"
}

resolve_mission() {
  if [ -n "$MISSION_FLAG" ]; then echo "$MISSION_FLAG"; return; fi
  if [ -n "${MC_MISSION:-}" ]; then echo "$MC_MISSION"; return; fi
  if [ -f "$CONFIG_DIR/config.json" ]; then
    local proj
    proj=$(resolve_project)
    # Try to extract project-specific default mission from config
    local val
    val=$(python3 -c "
import json,sys
try:
  c=json.load(open('$CONFIG_DIR/config.json'))
  p=c.get('projects',c.get('workspaces',{}))
  print(p.get('$proj',{}).get('default_mission',''))
except: pass
" 2>/dev/null || true)
    if [ -n "$val" ]; then echo "$val"; return; fi
  fi
  echo "default"
}

# DB resolution — MC_DB takes priority for backward compat
if [ -n "${MC_DB:-}" ]; then
  DB="$MC_DB"
  PROJECT="(custom)"
else
  PROJECT=$(resolve_project)
  DB="$CONFIG_DIR/projects/$PROJECT/mission-control.db"
fi

MISSION_NAME=$(resolve_mission)

# ═══════════════════════════════════════════
# SQL HELPERS (with WAL + busy_timeout)
# ═══════════════════════════════════════════

sql() { sqlite3 -batch -separator '|' "$DB" ".timeout 5000" "$1"; }
sql_col() { sqlite3 -batch -header -column "$DB" ".timeout 5000" "$1"; }
log_activity() {
  sql "INSERT INTO activity(mission_id,agent,action,target_type,target_id,detail)
    VALUES($MID,'$AGENT','$1','$2',$3,'$4');"
}

# ═══════════════════════════════════════════
# MISSION ID RESOLUTION
# ═══════════════════════════════════════════

resolve_mission_id() {
  local name="$1"
  local mid
  mid=$(sql "SELECT id FROM missions WHERE name='$name';")
  if [ -z "$mid" ]; then
    echo -e "${R}Mission '$name' not found.${N} Run: mc mission create $name" >&2
    exit 1
  fi
  echo "$mid"
}

# MID is set lazily — only for commands that need it
MID=""
ensure_mission_id() {
  if [ -z "$MID" ]; then
    MID=$(resolve_mission_id "$MISSION_NAME")
  fi
}

# Block if mission is completed or archived (allow paused — agents may need to finish work)
ensure_mission_not_closed() {
  ensure_mission_id
  local mstatus
  mstatus=$(sql "SELECT status FROM missions WHERE id=$MID;")
  if [[ "$mstatus" == "completed" || "$mstatus" == "archived" ]]; then
    echo -e "${R}Mission '$MISSION_NAME' is $mstatus.${N}" >&2
    return 1
  fi
}

# Block if mission is not active (paused/completed/archived)
ensure_mission_writable() {
  ensure_mission_id
  local mstatus
  mstatus=$(sql "SELECT status FROM missions WHERE id=$MID;")
  if [[ "$mstatus" != "active" ]]; then
    echo -e "${R}Mission '$MISSION_NAME' is $mstatus — cannot modify.${N}" >&2
    [[ "$mstatus" == "paused" ]] && echo -e "${Y}Resume: mc -p $PROJECT -m $MISSION_NAME mission resume${N}" >&2
    return 1
  fi
}

# ═══════════════════════════════════════════
# CONFIG HELPERS
# ═══════════════════════════════════════════

ensure_config() {
  if [ ! -f "$CONFIG_DIR/config.json" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.json" <<'CONF'
{
  "default_project": "default",
  "projects": {
    "default": {
      "default_mission": "default",
      "created_at": ""
    }
  }
}
CONF
  fi
}

update_config_project() {
  local proj_name="$1"
  ensure_config
  python3 -c "
import json, datetime
f='$CONFIG_DIR/config.json'
try:
  c=json.load(open(f))
except: c={'default_project':'default','projects':{}}
if 'projects' not in c: c['projects']={}
if '$proj_name' not in c['projects']:
  c['projects']['$proj_name']={
    'default_mission':'default',
    'created_at': datetime.datetime.now().isoformat()
  }
json.dump(c,open(f,'w'),indent=2)
"
}

# ═══════════════════════════════════════════
# COMMANDS: PROJECT MANAGEMENT
# ═══════════════════════════════════════════

cmd_project() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    create)
      local name="${1:?Usage: mc project create <name>}"
      local proj_dir="$CONFIG_DIR/projects/$name"
      if [ -d "$proj_dir" ]; then
        echo -e "${Y}Project '$name' already exists${N}"; return 0
      fi
      mkdir -p "$proj_dir"
      # Init DB for this project
      sqlite3 "$proj_dir/mission-control.db" < "$SCHEMA_DIR/schema.sql"
      sqlite3 "$proj_dir/mission-control.db" "PRAGMA journal_mode=WAL;" > /dev/null
      update_config_project "$name"
      echo -e "${G}Project '$name' created${N} → $proj_dir"
      ;;
    list)
      echo -e "${B}═══ PROJECTS ═══${N}"
      if [ -d "$CONFIG_DIR/projects" ]; then
        for d in "$CONFIG_DIR/projects"/*/; do
          [ -d "$d" ] || continue
          local proj_name
          proj_name=$(basename "$d")
          local marker=""
          [ "$proj_name" = "$PROJECT" ] && marker=" ${C}(current)${N}"
          local db_size=""
          if [ -f "$d/mission-control.db" ]; then
            db_size=$(du -h "$d/mission-control.db" | cut -f1 | tr -d ' ')
          fi
          echo -e "  $proj_name${marker}  ${db_size:+[$db_size]}"
        done
      else
        echo "  (none)"
      fi
      ;;
    current)
      echo -e "Project: ${C}$PROJECT${N}"
      echo -e "DB:      $DB"
      ;;
    *)
      echo "Usage: mc project <create|list|current>"
      ;;
  esac
}

# ═══════════════════════════════════════════
# COMMANDS: MISSION MANAGEMENT
# ═══════════════════════════════════════════

cmd_mission() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    create)
      local name="${1:?Usage: mc mission create <name> [-d \"description\"]}" desc=""
      shift
      while [[ $# -gt 0 ]]; do
        case "$1" in -d) desc="$2"; shift 2;; *) shift;; esac
      done
      local existing
      existing=$(sql "SELECT status FROM missions WHERE name='$(echo "$name" | sed "s/'/''/g")';")
      if [[ -n "$existing" ]]; then
        echo -e "${Y}Mission '$name' already exists (status: $existing)${N}"
        return 0
      fi
      sql "INSERT INTO missions(name,description) VALUES('$(echo "$name" | sed "s/'/''/g")','$(echo "$desc" | sed "s/'/''/g")');"
      echo -e "${G}Mission '$name' created${N}"
      ;;
    list)
      sql_col "SELECT id, name,
        COALESCE(description,'-') AS description,
        status,
        (SELECT COUNT(*) FROM tasks WHERE tasks.mission_id=missions.id AND tasks.status NOT IN ('done','cancelled')) AS open_tasks,
        substr(created_at,1,16) AS created
        FROM missions ORDER BY status, id;"
      ;;
    archive)
      local name="${1:?Usage: mc mission archive <name>}"
      sql "UPDATE missions SET status='archived', updated_at=datetime('now') WHERE name='$name';"
      echo -e "${Y}Mission '$name' archived${N}"
      ;;
    complete)
      # Complete a mission: archive + cleanup agents/crons/workspaces
      ensure_mission_id
      local pattern="$PROJECT-$MISSION_NAME-"
      local oc_profile_flag=""
      [ -n "${OPENCLAW_PROFILE:-}" ] && oc_profile_flag="--profile $OPENCLAW_PROFILE"

      echo -e "${B}═══ Mission Complete: $MISSION_NAME ═══${N}"
      echo ""

      # 1. Check open tasks
      local open
      open=$(sql "SELECT COUNT(*) FROM tasks WHERE mission_id=$MID AND status NOT IN ('done','cancelled');")
      if [ "$open" -gt 0 ]; then
        echo -e "${Y}Warning: $open open tasks remaining${N}"
        sql "SELECT '  #' || id || ' [' || status || '] ' || subject FROM tasks WHERE mission_id=$MID AND status NOT IN ('done','cancelled') ORDER BY id;"
        echo ""
      fi

      # 2. Archive mission
      sql "UPDATE missions SET status='completed', updated_at=datetime('now') WHERE id=$MID;"
      echo -e "${G}[1/4] Mission archived${N}"

      # 3. Remove cron jobs matching pattern (by name prefix, including monitor)
      echo -e "${C}[2/4] Removing cron jobs (${pattern}*)...${N}"
      local cron_json
      cron_json=$(openclaw $oc_profile_flag cron list --json 2>/dev/null || echo '{"jobs":[]}')
      local cron_matches
      cron_matches=$(echo "$cron_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for job in data.get('jobs', []):
    if job.get('name','').startswith('$pattern'):
        print(job['id'] + '|' + job['name'])" 2>/dev/null)
      if [ -n "$cron_matches" ]; then
        while IFS='|' read -r cron_id cron_name; do
          [[ -z "$cron_id" ]] && continue
          openclaw $oc_profile_flag cron rm "$cron_id" 2>/dev/null && \
            echo -e "  Removed cron: $cron_name ($cron_id)" || \
            echo -e "  ${Y}Failed to remove cron: $cron_name${N}"
        done <<< "$cron_matches"
      else
        echo "  (no matching crons)"
      fi

      # 4. Remove openclaw agents
      echo -e "${C}[3/4] Removing openclaw agents (${pattern}*)...${N}"
      local agents_list
      agents_list=$(openclaw $oc_profile_flag agents list --json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in (data if isinstance(data, list) else data.get('agents', [])):
    name = a.get('name','') or a.get('agentId','')
    if name.startswith('$pattern'):
        print(name)" 2>/dev/null || true)
      if [ -n "$agents_list" ]; then
        while IFS= read -r agent_name; do
          [ -z "$agent_name" ] && continue
          openclaw $oc_profile_flag agents delete "$agent_name" --force 2>/dev/null && \
            echo -e "  Removed agent: $agent_name" || \
            echo -e "  ${Y}Could not remove: $agent_name${N}"
        done <<< "$agents_list"
      fi

      # 5. Remove agent workspaces
      echo -e "${C}[4/4] Removing agent workspaces (${pattern}*)...${N}"
      local aws_dir="$CONFIG_DIR/agent_workspaces"
      if [ -d "$aws_dir" ]; then
        for d in "$aws_dir"/${pattern}*/; do
          [ -d "$d" ] || continue
          rm -r "$d" && echo -e "  Removed: $(basename "$d")"
        done
      fi

      # 6. Remove agents from MC fleet
      if [ -n "$agents_list" ]; then
        while IFS= read -r agent_name; do
          [ -z "$agent_name" ] && continue
          sql "DELETE FROM agents WHERE name='$agent_name';"
        done <<< "$agents_list"
      fi

      echo ""
      echo -e "${G}Mission '$MISSION_NAME' completed and cleaned up${N}"
      ;;
    pause)
      ensure_mission_id
      sql "UPDATE missions SET status='paused', updated_at=datetime('now') WHERE id=$MID;"
      log_activity "mission_paused" "mission" "$MID" "manual pause"

      # Disable crons for this mission's agents
      local pattern="$PROJECT-$MISSION_NAME-"
      local oc_profile_flag=""
      [ -n "${OPENCLAW_PROFILE:-}" ] && oc_profile_flag="--profile $OPENCLAW_PROFILE"
      local cron_json
      cron_json=$(openclaw $oc_profile_flag cron list --json 2>/dev/null || echo '{"jobs":[]}')
      local cron_ids
      cron_ids=$(echo "$cron_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for job in data.get('jobs', []):
    if job.get('name','').startswith('$pattern'):
        print(job['id'])" 2>/dev/null)
      while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        openclaw $oc_profile_flag cron disable "$cid" 2>/dev/null && \
          echo -e "  Disabled cron: $cid" || true
      done <<< "$cron_ids"

      echo -e "${Y}⏸ Mission '$MISSION_NAME' paused${N}"
      ;;
    resume)
      ensure_mission_id
      sql "UPDATE missions SET status='active', updated_at=datetime('now') WHERE id=$MID;"
      log_activity "mission_resumed" "mission" "$MID" "resumed"

      # Enable crons for this mission's agents
      local pattern="$PROJECT-$MISSION_NAME-"
      local oc_profile_flag=""
      [ -n "${OPENCLAW_PROFILE:-}" ] && oc_profile_flag="--profile $OPENCLAW_PROFILE"
      local cron_json
      cron_json=$(openclaw $oc_profile_flag cron list --json 2>/dev/null || echo '{"jobs":[]}')
      local cron_ids
      cron_ids=$(echo "$cron_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for job in data.get('jobs', []):
    if job.get('name','').startswith('$pattern'):
        print(job['id'])" 2>/dev/null)
      while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        openclaw $oc_profile_flag cron enable "$cid" 2>/dev/null && \
          echo -e "  Enabled cron: $cid" || true
      done <<< "$cron_ids"

      # Show user instructions if any
      local instructions
      instructions=$(sql "SELECT user_instructions FROM missions WHERE id=$MID;")
      if [[ -n "$instructions" ]]; then
        echo -e "${C}📋 User instructions:${N} $instructions"
      fi

      echo -e "${G}▶ Mission '$MISSION_NAME' resumed${N}"
      ;;
    instruct)
      ensure_mission_id
      local text="${1:?Usage: mc mission instruct \"text\"}"
      sql "UPDATE missions SET user_instructions='$(echo "$text" | sed "s/'/''/g")', updated_at=datetime('now') WHERE id=$MID;"
      # Also record as a message to mc-architect
      sql "INSERT INTO messages(mission_id,from_agent,to_agent,body,msg_type)
        VALUES($MID,'$AGENT','mc-architect','$(echo "$text" | sed "s/'/''/g")','alert');"
      log_activity "mission_instruct" "mission" "$MID" "$(echo "$text" | sed "s/'/''/g")"
      echo -e "${G}📋 Instructions saved${N}: $text"
      ;;
    status)
      ensure_mission_id
      local mrow
      mrow=$(sql "SELECT name || '|' || status || '|' || COALESCE(user_instructions,'') || '|' || COALESCE(description,'') FROM missions WHERE id=$MID;")
      local mname mstatus minstr mdesc
      IFS='|' read -r mname mstatus minstr mdesc <<< "$mrow"

      echo -e "${B}═══ MISSION STATUS ═══${N}"
      echo -e "  Project:     ${C}$PROJECT${N}"
      echo -e "  Mission:     ${C}$mname${N}"
      echo -e "  Description: ${mdesc:--}"
      case "$mstatus" in
        active)    echo -e "  Status:      ${G}▶ ACTIVE${N}" ;;
        paused)    echo -e "  Status:      ${Y}⏸ PAUSED${N}" ;;
        completed) echo -e "  Status:      ${G}✓ COMPLETED${N}" ;;
        archived)  echo -e "  Status:      archived" ;;
      esac
      echo ""

      # Progress
      echo -e "${C}Progress:${N}"
      for st in pending claimed in_progress review blocked done cancelled; do
        local cnt
        cnt=$(sql "SELECT COUNT(*) FROM tasks WHERE status='$st' AND mission_id=$MID;")
        [[ "$cnt" -eq 0 ]] && continue
        echo -e "  $st: $cnt"
      done
      echo ""

      # User instructions
      if [[ -n "$minstr" ]]; then
        echo -e "${C}📋 User Instructions:${N}"
        echo -e "  $minstr"
        echo ""
      fi

      # Next scheduled tasks
      local sched
      sched=$(sql "SELECT id || ' ' || subject || ' ⏰' || substr(scheduled_at,1,16) FROM tasks WHERE mission_id=$MID AND scheduled_at IS NOT NULL AND scheduled_at > datetime('now') AND status NOT IN ('done','cancelled') ORDER BY scheduled_at LIMIT 5;")
      if [[ -n "$sched" ]]; then
        echo -e "${C}⏰ Upcoming Scheduled:${N}"
        while IFS= read -r line; do
          echo -e "  #$line"
        done <<< "$sched"
        echo ""
      fi
      ;;
    current)
      ensure_mission_id
      echo -e "Mission:   ${C}$MISSION_NAME${N} (id=$MID)"
      echo -e "Project:   $PROJECT"
      ;;
    *)
      echo "Usage: mc mission <create|list|archive|complete|pause|resume|instruct|status|current>"
      ;;
  esac
}

# ═══════════════════════════════════════════
# COMMANDS: MIGRATION
# ═══════════════════════════════════════════

cmd_migrate() {
  # ── Phase 1: Rename workspaces/ → projects/ directory ──
  if [ -d "$CONFIG_DIR/workspaces" ] && [ ! -d "$CONFIG_DIR/projects" ]; then
    mv "$CONFIG_DIR/workspaces" "$CONFIG_DIR/projects"
    echo -e "${G}Renamed workspaces/ → projects/${N}"
  fi

  # ── Phase 2: Migrate config.json keys ──
  if [ -f "$CONFIG_DIR/config.json" ]; then
    python3 -c "
import json
f='$CONFIG_DIR/config.json'
c=json.load(open(f))
changed=False
if 'default_workspace' in c and 'default_project' not in c:
  c['default_project']=c.pop('default_workspace'); changed=True
if 'workspaces' in c and 'projects' not in c:
  c['projects']=c.pop('workspaces'); changed=True
if changed:
  json.dump(c,open(f,'w'),indent=2)
  print('  Config keys migrated')
"
  fi

  # ── Phase 3: Legacy DB migration (v0.1 → v0.2) ──
  local old_db="$CONFIG_DIR/mission-control.db"
  local new_dir="$CONFIG_DIR/projects/default"
  local new_db="$new_dir/mission-control.db"

  if [ -f "$old_db" ]; then
    if [ -f "$new_db" ]; then
      echo -e "${Y}Target already exists: $new_db${N}"
      echo "  Remove it first or skip legacy migration."
    else
      mkdir -p "$new_dir"

      # Create new DB with updated schema
      sqlite3 "$new_db" < "$SCHEMA_DIR/schema.sql"
      sqlite3 "$new_db" "PRAGMA journal_mode=WAL;" > /dev/null

      # Migrate data from old DB (single session for ATTACH)
      # Detect schema version: old (v0.1) has no mission_id in tasks
      local has_mission_id
      has_mission_id=$(sqlite3 "$old_db" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='mission_id';")

      if [ "$has_mission_id" = "0" ]; then
        # v0.1 schema — no mission_id columns
        sqlite3 "$new_db" <<MIGRATE_SQL
ATTACH '$old_db' AS old;
INSERT OR IGNORE INTO agents SELECT * FROM old.agents;
INSERT INTO tasks(id,mission_id,subject,description,status,owner,created_by,priority,blocks,blocked_by,tags,created_at,updated_at,claimed_at,completed_at)
  SELECT id,1,subject,description,status,owner,created_by,priority,blocks,blocked_by,tags,created_at,updated_at,claimed_at,completed_at FROM old.tasks;
INSERT INTO messages(id,mission_id,from_agent,to_agent,task_id,body,msg_type,created_at,read_at)
  SELECT id,1,from_agent,to_agent,task_id,body,msg_type,created_at,read_at FROM old.messages;
INSERT INTO activity(id,mission_id,agent,action,target_type,target_id,detail,created_at)
  SELECT id,1,agent,action,target_type,target_id,detail,created_at FROM old.activity;
DETACH old;
MIGRATE_SQL
      else
        # v0.2+ schema — mission_id already present
        sqlite3 "$new_db" <<MIGRATE_SQL
ATTACH '$old_db' AS old;
INSERT OR IGNORE INTO missions SELECT * FROM old.missions;
INSERT OR IGNORE INTO agents SELECT * FROM old.agents;
INSERT INTO tasks SELECT * FROM old.tasks;
INSERT INTO messages SELECT * FROM old.messages;
INSERT INTO activity SELECT * FROM old.activity;
DETACH old;
MIGRATE_SQL
      fi

      update_config_project "default"

      echo -e "${G}Legacy migration complete${N}"
      echo -e "  Old: $old_db"
      echo -e "  New: $new_db"
      echo -e "  ${Y}Old DB kept as backup. Remove manually when ready.${N}"
    fi
  fi

  # ── Phase 4: v0.3 schema migration (add new columns) ──
  # Apply to all project DBs
  echo -e "${B}Checking v0.3 schema...${N}"
  local migrated=false

  if [ -d "$CONFIG_DIR/projects" ]; then
    for d in "$CONFIG_DIR/projects"/*/; do
      [ -d "$d" ] || continue
      local pdb="$d/mission-control.db"
      [ -f "$pdb" ] || continue
      local pname
      pname=$(basename "$d")

      # missions.user_instructions
      local has_col
      has_col=$(sqlite3 "$pdb" "SELECT COUNT(*) FROM pragma_table_info('missions') WHERE name='user_instructions';")
      if [ "$has_col" = "0" ]; then
        sqlite3 "$pdb" "ALTER TABLE missions ADD COLUMN user_instructions TEXT DEFAULT NULL;"
        echo -e "  ${G}[$pname] Added missions.user_instructions${N}"
        migrated=true
      fi

      # missions.last_report_at
      has_col=$(sqlite3 "$pdb" "SELECT COUNT(*) FROM pragma_table_info('missions') WHERE name='last_report_at';")
      if [ "$has_col" = "0" ]; then
        sqlite3 "$pdb" "ALTER TABLE missions ADD COLUMN last_report_at TEXT DEFAULT NULL;"
        echo -e "  ${G}[$pname] Added missions.last_report_at${N}"
        migrated=true
      fi

      # tasks.task_type
      has_col=$(sqlite3 "$pdb" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='task_type';")
      if [ "$has_col" = "0" ]; then
        sqlite3 "$pdb" "ALTER TABLE tasks ADD COLUMN task_type TEXT DEFAULT 'normal';"
        echo -e "  ${G}[$pname] Added tasks.task_type${N}"
        migrated=true
      fi

      # tasks.scheduled_at
      has_col=$(sqlite3 "$pdb" "SELECT COUNT(*) FROM pragma_table_info('tasks') WHERE name='scheduled_at';")
      if [ "$has_col" = "0" ]; then
        sqlite3 "$pdb" "ALTER TABLE tasks ADD COLUMN scheduled_at TEXT DEFAULT NULL;"
        echo -e "  ${G}[$pname] Added tasks.scheduled_at${N}"
        migrated=true
      fi
    done
  fi

  if [ "$migrated" = true ]; then
    echo -e "${G}v0.3 migration complete${N}"
  else
    echo -e "${Y}Already at v0.3 schema${N}"
  fi
}

# ═══════════════════════════════════════════
# COMMANDS: TASKS
# ═══════════════════════════════════════════

cmd_init() {
  mkdir -p "$(dirname "$DB")"
  sqlite3 "$DB" < "$SCHEMA_DIR/schema.sql"
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;" > /dev/null
  [[ "$PROJECT" != "(custom)" ]] && update_config_project "$PROJECT"
  echo -e "${G}Initialized${N} $DB (project: $PROJECT)"
}

cmd_register() {
  local name="${1:?Usage: mc register <name> [--role role]}" role=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in --role) role="$2"; shift 2;; *) shift;; esac; done
  sql "INSERT OR REPLACE INTO agents(name,role,last_seen,status) VALUES('$name','$role',datetime('now'),'idle');"
  ensure_mission_id
  log_activity "agent_registered" "agent" 0 "$name ($role)"
  echo -e "${G}Registered${N} $name${role:+ as $role}"
}

cmd_checkin() {
  sql "INSERT OR REPLACE INTO agents(name,role,last_seen,status,session_id,registered_at)
    VALUES('$AGENT',
      COALESCE((SELECT role FROM agents WHERE name='$AGENT'),''),
      datetime('now'),
      COALESCE((SELECT CASE WHEN (SELECT COUNT(*) FROM tasks WHERE owner='$AGENT' AND status='in_progress')>0 THEN 'busy' ELSE 'idle' END),'idle'),
      COALESCE((SELECT session_id FROM agents WHERE name='$AGENT'),''),
      COALESCE((SELECT registered_at FROM agents WHERE name='$AGENT'),datetime('now')));"
  ensure_mission_id

  # Mission status guard
  local mstatus
  mstatus=$(sql "SELECT status FROM missions WHERE id=$MID;")
  case "$mstatus" in
    paused)    echo "MISSION_PAUSED"; return 0 ;;
    completed) echo "MISSION_COMPLETED"; return 0 ;;
    archived)  echo "MISSION_ARCHIVED"; return 0 ;;
  esac

  log_activity "checkin" "agent" 0 ""
  local unread
  unread=$(sql "SELECT COUNT(*) FROM messages WHERE to_agent='$AGENT' AND read_at IS NULL AND (mission_id=$MID OR mission_id IS NULL);")
  if [[ "$unread" -gt 0 ]]; then
    echo -e "${Y}${unread} unread messages${N} — run: mc inbox --unread"
  else
    echo -e "${G}HEARTBEAT_OK${N} ($AGENT)"
  fi
}

cmd_add() {
  ensure_mission_writable
  local subject="" desc="" priority=0 assignee="" task_type="normal" scheduled_at=""
  subject="${1:?Usage: mc add \"Subject\" [-d desc] [-p 0|1|2] [--for agent] [--type normal|checkpoint] [--at \"YYYY-MM-DD HH:MM\"]}"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) desc="$2"; shift 2;;
      -p) priority="$2"; shift 2;;
      --for) assignee="$2"; shift 2;;
      --type) task_type="$2"; shift 2;;
      --at) scheduled_at="$2"; shift 2;;
      *) shift;;
    esac
  done
  local status="pending"
  [[ -n "$assignee" ]] && status="claimed"
  local sched_sql="NULL"
  [[ -n "$scheduled_at" ]] && sched_sql="'$scheduled_at'"
  local id
  id=$(sql "INSERT INTO tasks(mission_id,subject,description,status,owner,created_by,priority,task_type,scheduled_at,claimed_at)
    VALUES($MID,'$(echo "$subject" | sed "s/'/''/g")','$(echo "$desc" | sed "s/'/''/g")','$status','$assignee','$AGENT',$priority,'$task_type',$sched_sql,$([ -n "$assignee" ] && echo "datetime('now')" || echo "NULL"))
    RETURNING id;")
  log_activity "task_created" "task" "$id" "$subject"
  local extra=""
  [[ -n "$assignee" ]] && extra=" → $assignee"
  [[ "$task_type" == "checkpoint" ]] && extra="$extra 🏁 checkpoint"
  [[ -n "$scheduled_at" ]] && extra="$extra ⏰ $scheduled_at"
  echo -e "${G}#$id${N} $subject${extra}"
}

cmd_list() {
  ensure_mission_id
  local where="mission_id=$MID" show_all=false show_scheduled=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) where="$where AND status='$2'"; shift 2;;
      --owner) where="$where AND owner='$2'"; shift 2;;
      --mine) where="$where AND owner='$AGENT'"; shift;;
      --all) show_all=true; show_scheduled=true; shift;;
      *) shift;;
    esac
  done
  if [[ "$show_all" == false ]]; then
    where="$where AND status NOT IN ('done','cancelled')"
  fi
  # Hide future scheduled tasks by default
  if [[ "$show_scheduled" == false ]]; then
    where="$where AND (scheduled_at IS NULL OR scheduled_at <= datetime('now'))"
  fi
  sql_col "SELECT id, subject,
    CASE status WHEN 'done' THEN '✓' WHEN 'in_progress' THEN '▶' WHEN 'claimed' THEN '◉' WHEN 'blocked' THEN '✗' WHEN 'review' THEN '⟳' ELSE '○' END || ' ' || status AS st,
    COALESCE(owner,'-') AS owner,
    CASE priority WHEN 2 THEN '!!!' WHEN 1 THEN '!' ELSE '' END
      || CASE WHEN task_type='checkpoint' THEN ' 🏁' ELSE '' END
      || CASE WHEN scheduled_at IS NOT NULL AND scheduled_at > datetime('now') THEN ' ⏰' || substr(scheduled_at,1,16) ELSE '' END AS flags
    FROM tasks WHERE $where ORDER BY priority DESC, id;"
}

cmd_claim() {
  ensure_mission_writable
  local id="${1:?Usage: mc claim <id>}"
  local current status sched
  current=$(sql "SELECT owner FROM tasks WHERE id=$id AND mission_id=$MID;")
  status=$(sql "SELECT status FROM tasks WHERE id=$id AND mission_id=$MID;")
  sched=$(sql "SELECT scheduled_at FROM tasks WHERE id=$id AND mission_id=$MID;")
  if [[ "$status" == "blocked" ]]; then
    echo -e "${R}#$id is blocked — resolve blockers first${N}"; return 1
  fi
  if [[ -n "$sched" && "$sched" > "$(date -u '+%Y-%m-%d %H:%M')" ]]; then
    echo -e "${R}#$id is scheduled for $sched — cannot claim yet${N}"; return 1
  fi
  if [[ -n "$current" && "$current" != "$AGENT" ]]; then
    echo -e "${R}Already claimed by $current${N}"; return 1
  fi
  sql "UPDATE tasks SET owner='$AGENT', status='claimed', claimed_at=datetime('now'), updated_at=datetime('now') WHERE id=$id AND mission_id=$MID;"
  log_activity "task_claimed" "task" "$id" ""
  echo -e "${G}Claimed #$id${N}"
}

cmd_start() {
  ensure_mission_writable
  local id="${1:?Usage: mc start <id>}"
  local status sched
  status=$(sql "SELECT status FROM tasks WHERE id=$id AND mission_id=$MID;")
  sched=$(sql "SELECT scheduled_at FROM tasks WHERE id=$id AND mission_id=$MID;")
  if [[ "$status" == "blocked" ]]; then
    echo -e "${R}#$id is blocked — resolve blockers first${N}"; return 1
  fi
  if [[ -n "$sched" && "$sched" > "$(date -u '+%Y-%m-%d %H:%M')" ]]; then
    echo -e "${R}#$id is scheduled for $sched — cannot start yet${N}"; return 1
  fi
  sql "UPDATE tasks SET status='in_progress', updated_at=datetime('now') WHERE id=$id AND mission_id=$MID AND owner='$AGENT';"
  sql "UPDATE agents SET status='busy' WHERE name='$AGENT';"
  log_activity "task_started" "task" "$id" ""
  echo -e "${C}▶ Working on #$id${N}"
}

cmd_done() {
  ensure_mission_not_closed
  local id="${1:?Usage: mc done <id> [-m note]}" note=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in -m) note="$2"; shift 2;; *) shift;; esac; done
  sql "UPDATE tasks SET status='done', completed_at=datetime('now'), updated_at=datetime('now') WHERE id=$id AND mission_id=$MID;"
  sql "UPDATE agents SET status='idle' WHERE name='$AGENT';"
  log_activity "task_completed" "task" "$id" "$(echo "$note" | sed "s/'/''/g")"
  [[ -n "$note" ]] && sql "INSERT INTO messages(mission_id,from_agent,task_id,body,msg_type) VALUES($MID,'$AGENT',$id,'$(echo "$note" | sed "s/'/''/g")','status');"
  echo -e "${G}✓ Done #$id${N}${note:+ — $note}"

  # Unblock tasks that were blocked by this task
  local blocked_tasks
  blocked_tasks=$(sql "SELECT id, blocked_by FROM tasks WHERE status='blocked' AND mission_id=$MID AND blocked_by LIKE '%$id%';")
  while IFS='|' read -r tid tblocked; do
    [[ -z "$tid" ]] && continue
    # Remove completed task id from blocked_by JSON array
    local new_blocked
    new_blocked=$(echo "$tblocked" | python3 -c "
import sys, json
try:
    arr = json.loads(sys.stdin.read().strip())
    arr = [x for x in arr if x != $id]
    print(json.dumps(arr))
except: print('[]')" 2>/dev/null || echo "[]")
    sql "UPDATE tasks SET blocked_by='$new_blocked', updated_at=datetime('now') WHERE id=$tid AND mission_id=$MID;"
    # If no more blockers, set to pending
    if [[ "$new_blocked" == "[]" ]]; then
      sql "UPDATE tasks SET status='pending' WHERE id=$tid AND mission_id=$MID;"
      log_activity "task_unblocked" "task" "$tid" "unblocked by #$id completion"
      echo -e "${C}↳ #$tid unblocked${N}"
    fi
  done <<< "$blocked_tasks"

  # Checkpoint auto-pause: if completed task is a checkpoint, pause the mission
  local ttype
  ttype=$(sql "SELECT task_type FROM tasks WHERE id=$id AND mission_id=$MID;")
  if [[ "$ttype" == "checkpoint" ]]; then
    sql "UPDATE missions SET status='paused', updated_at=datetime('now') WHERE id=$MID;"
    log_activity "mission_paused" "mission" "$MID" "checkpoint #$id reached"
    echo -e "${Y}🏁 Checkpoint reached — mission paused${N}"

    # Disable crons for this mission's agents
    local pattern="$PROJECT-$MISSION_NAME-"
    local oc_profile_flag=""
    [ -n "${OPENCLAW_PROFILE:-}" ] && oc_profile_flag="--profile $OPENCLAW_PROFILE"
    local cron_json
    cron_json=$(openclaw $oc_profile_flag cron list --json 2>/dev/null || echo '{"jobs":[]}')
    local cron_ids
    cron_ids=$(echo "$cron_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for job in data.get('jobs', []):
    if job.get('name','').startswith('$pattern'):
        print(job['id'])" 2>/dev/null)
    while IFS= read -r cid; do
      [[ -z "$cid" ]] && continue
      openclaw $oc_profile_flag cron disable "$cid" 2>/dev/null && \
        echo -e "  Disabled cron: $cid" || true
    done <<< "$cron_ids"
    echo -e "${Y}Resume with: mc -p $PROJECT -m $MISSION_NAME mission resume${N}"
  fi
}

cmd_block() {
  ensure_mission_writable
  local id="${1:?Usage: mc block <id> --by <other-id>}" by=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in --by) by="$2"; shift 2;; *) shift;; esac; done
  [[ -z "$by" ]] && { echo "Usage: mc block <id> --by <other-id>"; return 1; }
  sql "UPDATE tasks SET status='blocked', updated_at=datetime('now'),
    blocked_by=json_insert(blocked_by, '\$[#]', $by) WHERE id=$id AND mission_id=$MID;"
  log_activity "task_blocked" "task" "$id" "by #$by"
  echo -e "${R}✗ #$id blocked by #$by${N}"
}

cmd_board() {
  ensure_mission_id

  # Show mission status in header
  local mstatus
  mstatus=$(sql "SELECT status FROM missions WHERE id=$MID;")
  echo -e "${B}═══ MISSION CONTROL ═══${N}  $(date '+%H:%M')  agent: ${C}$AGENT${N}"
  echo -e "  project: ${C}$PROJECT${N}  mission: ${C}$MISSION_NAME${N}"
  [[ "$mstatus" == "paused" ]] && echo -e "  status: ${Y}⏸ PAUSED${N}"
  echo ""

  for status in pending claimed in_progress review blocked done; do
    local count
    count=$(sql "SELECT COUNT(*) FROM tasks WHERE status='$status' AND mission_id=$MID;")
    [[ "$count" -eq 0 ]] && continue
    local icon
    case $status in pending) icon="○";; claimed) icon="◉";; in_progress) icon="▶";; review) icon="⟳";; blocked) icon="✗";; done) icon="✓";; esac
    echo -e "${B}── $icon $status ($count) ──${N}"
    sql "SELECT '  #' || id || ' ' || subject
      || CASE WHEN owner IS NOT NULL THEN ' [' || owner || ']' ELSE '' END
      || CASE WHEN task_type='checkpoint' THEN ' 🏁' ELSE '' END
      || CASE WHEN scheduled_at IS NOT NULL AND scheduled_at > datetime('now') THEN ' ⏰' || substr(scheduled_at,1,16) ELSE '' END
      FROM tasks WHERE status='$status' AND mission_id=$MID ORDER BY priority DESC, id LIMIT 10;"
    echo ""
  done

  # Show upcoming scheduled tasks
  local sched_count
  sched_count=$(sql "SELECT COUNT(*) FROM tasks WHERE mission_id=$MID AND scheduled_at IS NOT NULL AND scheduled_at > datetime('now') AND status NOT IN ('done','cancelled');")
  if [[ "$sched_count" -gt 0 ]]; then
    echo -e "${B}── ⏰ scheduled ($sched_count) ──${N}"
    sql "SELECT '  #' || id || ' ' || subject || ' ⏰' || substr(scheduled_at,1,16) || CASE WHEN owner IS NOT NULL THEN ' [' || owner || ']' ELSE '' END FROM tasks WHERE mission_id=$MID AND scheduled_at IS NOT NULL AND scheduled_at > datetime('now') AND status NOT IN ('done','cancelled') ORDER BY scheduled_at LIMIT 5;"
    echo ""
  fi
}

# ═══════════════════════════════════════════
# COMMANDS: MESSAGES
# ═══════════════════════════════════════════

cmd_msg() {
  ensure_mission_not_closed
  local to="${1:?Usage: mc msg <agent> \"body\" [--task id] [--type TYPE]}" body="${2:?}" task_id="NULL" msg_type="comment"
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in --task) task_id="$2"; shift 2;; --type) msg_type="$2"; shift 2;; *) shift;; esac
  done
  sql "INSERT INTO messages(mission_id,from_agent,to_agent,task_id,body,msg_type) VALUES($MID,'$AGENT','$to',$task_id,'$(echo "$body" | sed "s/'/''/g")','$msg_type');"
  log_activity "message_sent" "message" 0 "to:$to type:$msg_type"
  echo -e "${G}→ $to${N}: $body"
}

cmd_broadcast() {
  ensure_mission_not_closed
  local body="${1:?Usage: mc broadcast \"body\"}"
  sql "INSERT INTO messages(mission_id,from_agent,to_agent,body,msg_type) VALUES($MID,'$AGENT',NULL,'$(echo "$body" | sed "s/'/''/g")','alert');"
  log_activity "broadcast" "message" 0 "$body"
  echo -e "${Y}📢 Broadcast:${N} $body"
}

cmd_inbox() {
  ensure_mission_id
  local where="(to_agent='$AGENT' OR to_agent IS NULL) AND (mission_id=$MID OR mission_id IS NULL)"
  [[ "${1:-}" == "--unread" ]] && where="$where AND read_at IS NULL"
  sql_col "SELECT id, from_agent AS 'from', body, msg_type AS type,
    CASE WHEN read_at IS NULL THEN '●' ELSE '' END AS new,
    substr(created_at,1,16) AS at
    FROM messages WHERE $where ORDER BY created_at DESC LIMIT 20;"
  sql "UPDATE messages SET read_at=datetime('now') WHERE to_agent='$AGENT' AND read_at IS NULL AND (mission_id=$MID OR mission_id IS NULL);"
}

# ═══════════════════════════════════════════
# COMMANDS: FLEET
# ═══════════════════════════════════════════

cmd_fleet() {
  echo -e "${B}═══ FLEET STATUS ═══${N}"
  sql_col "SELECT name, role,
    CASE status WHEN 'busy' THEN '▶ busy' WHEN 'idle' THEN '○ idle' ELSE '✗ offline' END AS status,
    COALESCE((SELECT subject FROM tasks WHERE owner=agents.name AND status='in_progress' LIMIT 1), '-') AS working_on,
    substr(last_seen,1,16) AS last_seen
    FROM agents ORDER BY status, name;"
}

cmd_feed() {
  ensure_mission_id
  local limit=20 agent_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --last) limit="$2"; shift 2;; --agent) agent_filter="AND agent='$2'"; shift 2;; *) shift;; esac
  done
  sql_col "SELECT substr(created_at,1,16) AS at, agent, action, detail
    FROM activity WHERE mission_id=$MID $agent_filter ORDER BY id DESC LIMIT $limit;"
}

cmd_summary() {
  ensure_mission_id
  echo -e "${B}═══ SUMMARY ═══${N}"
  echo -e "  project: ${C}$PROJECT${N}  mission: ${C}$MISSION_NAME${N}"
  echo ""
  echo -e "${C}Fleet:${N}"
  sql "SELECT '  ' || name || ' (' || status || ')' || CASE WHEN role != '' THEN ' — ' || role ELSE '' END FROM agents;"
  echo ""
  echo -e "${C}Open tasks:${N} $(sql "SELECT COUNT(*) FROM tasks WHERE status NOT IN ('done','cancelled') AND mission_id=$MID;")"
  echo -e "${C}In progress:${N} $(sql "SELECT COUNT(*) FROM tasks WHERE status='in_progress' AND mission_id=$MID;")"
  echo -e "${C}Blocked:${N} $(sql "SELECT COUNT(*) FROM tasks WHERE status='blocked' AND mission_id=$MID;")"
  echo ""
  echo -e "${C}Last 5 events:${N}"
  sql "SELECT '  [' || substr(created_at,1,16) || '] ' || agent || ': ' || action || CASE WHEN detail != '' THEN ' — ' || detail ELSE '' END FROM activity WHERE mission_id=$MID ORDER BY id DESC LIMIT 5;"
}

cmd_whoami() {
  echo -e "Agent:     ${C}$AGENT${N}"
  echo -e "Project:   ${C}$PROJECT${N}"
  echo -e "Mission:   ${C}$MISSION_NAME${N}"
  echo -e "DB:        $DB"
  local role
  role=$(sql "SELECT role FROM agents WHERE name='$AGENT';" 2>/dev/null || echo "unregistered")
  echo -e "Role:      ${role:-unregistered}"
}

cmd_plan() {
  local subcmd="${1:-show}"
  shift 2>/dev/null || true
  local plan_file="$CONFIG_DIR/projects/$PROJECT/plan.md"
  case "$subcmd" in
    show)
      if [[ ! -f "$plan_file" ]]; then
        echo -e "${Y}No plan found.${N} Set one with: mc -p $PROJECT plan set <file>"
        return 0
      fi
      cat "$plan_file"
      ;;
    set)
      local src="${1:?Usage: mc plan set <file>}"
      [[ -f "$src" ]] || { echo -e "${R}File not found: $src${N}" >&2; return 1; }
      mkdir -p "$(dirname "$plan_file")"
      cp "$src" "$plan_file"
      echo -e "${G}Plan set${N} → $plan_file"
      ;;
    path)
      echo "$plan_file"
      ;;
    *) echo "Usage: mc -p <project> plan <show|set|path>" ;;
  esac
}

cmd_help() {
  cat <<'EOF'
Mission Control v0.3 — Coordination for OpenClaw agent fleets

USAGE: mc [-p project] [-m mission] <command> [args]

TASKS:
  add "Subject" [-d desc] [-p 0|1|2] [--for agent]    Create task
      [--type normal|checkpoint] [--at "YYYY-MM-DD HH:MM"]
  list [--status S] [--owner A] [--mine] [--all]       List tasks
  claim <id>                                           Claim a task
  start <id>                                           Begin work
  done <id> [-m "note"]                                Complete task
  block <id> --by <other-id>                           Mark blocked
  board                                                Kanban view

MESSAGES:
  msg <agent> "body" [--task id] [--type TYPE]         Send message
  broadcast "body"                                     Message all
  inbox [--unread]                                     Read messages

FLEET:
  register <name> [--role role]                        Add agent
  checkin                                              Heartbeat
  fleet                                                Show fleet
  whoami                                               Show identity

FEED:
  feed [--last N] [--agent NAME]                       Activity log
  summary                                              Fleet summary

PROJECT:
  project create <name>                                Create project
  project list                                         List projects
  project current                                      Show current

MISSION:
  mission create <name> [-d "description"]             Create mission
  mission list                                         List missions
  mission archive <name>                               Archive mission
  mission complete                                     Complete + cleanup agents/crons
  mission pause                                        Pause mission + disable crons
  mission resume                                       Resume mission + enable crons
  mission instruct "text"                              Set user instructions
  mission status                                       Show mission status & progress
  mission current                                      Show current

PLAN:
  plan [show]                                          Show mission plan
  plan set <file>                                      Set plan from file
  plan path                                            Show plan file path

MIGRATION:
  migrate                                              Migrate DB schema

GLOBAL FLAGS:
  -p, --project <name>     Target project (-w/--workspace also accepted)
  -m, --mission <name>     Target mission

ENV:
  MC_AGENT       Your agent name (default: $USER)
  MC_PROJECT     Project name (default: "default") (MC_WORKSPACE also accepted)
  MC_MISSION     Mission name (default: "default")
  MC_DB          Direct DB path (overrides project resolution)

QUICK START:
  mc init
  mc register jarvis --role lead
  mc add "Research competitors" --for researcher
  mc board
EOF
}

# ═══════════════════════════════════════════
# DISPATCH
# ═══════════════════════════════════════════

# Commands that don't need existing DB
case "${1:-help}" in
  init|help|-h|--help|project|workspace|migrate|plan) ;;
  *)
    if [[ ! -f "$DB" ]]; then
      echo -e "${Y}No database found at $DB${N}" >&2
      echo -e "Run: mc init${PROJECT_FLAG:+ -p $PROJECT_FLAG}" >&2
      exit 1
    fi
    ;;
esac

case "${1:-help}" in
  init)      cmd_init ;;
  register)  shift; cmd_register "$@" ;;
  checkin)   cmd_checkin ;;
  add)       shift; cmd_add "$@" ;;
  list)      shift; cmd_list "$@" ;;
  claim)     shift; cmd_claim "$@" ;;
  start)     shift; cmd_start "$@" ;;
  done)      shift; cmd_done "$@" ;;
  block)     shift; cmd_block "$@" ;;
  board)     cmd_board ;;
  msg)       shift; cmd_msg "$@" ;;
  broadcast) shift; cmd_broadcast "$@" ;;
  inbox)     shift; cmd_inbox "$@" ;;
  fleet)     cmd_fleet ;;
  feed)      shift; cmd_feed "$@" ;;
  summary)   cmd_summary ;;
  whoami)    cmd_whoami ;;
  project)   shift; cmd_project "$@" ;;
  workspace) shift; cmd_project "$@" ;;  # alias for backward compat
  mission)   shift; cmd_mission "$@" ;;
  plan)      shift; cmd_plan "$@" ;;
  migrate)   cmd_migrate ;;
  help|-h|--help) cmd_help ;;
  *)         echo "Unknown: $1"; cmd_help ;;
esac
