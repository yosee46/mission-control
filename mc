#!/usr/bin/env bash
# Mission Control v0.2 — Coordination layer for OpenClaw agent fleets
# Zero dependencies beyond bash + sqlite3
# Supports workspaces (physical DB isolation) and multi-mission (logical isolation)
set -euo pipefail

AGENT="${MC_AGENT:-$(whoami)}"
SCHEMA_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.openclaw"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

# ═══════════════════════════════════════════
# GLOBAL FLAG PARSING (before subcommand)
# ═══════════════════════════════════════════

WS_FLAG=""
MISSION_FLAG=""
ARGS=()

# Only parse global flags BEFORE the subcommand (first non-flag argument)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace) WS_FLAG="$2"; shift 2;;
    -m|--mission)   MISSION_FLAG="$2"; shift 2;;
    -*) ARGS+=("$1"); shift;;   # unknown flag before subcommand
    *)  break;;                  # subcommand found — stop global parsing
  esac
done

# Remaining args = subcommand + its arguments
ARGS+=("$@")
set -- "${ARGS[@]+"${ARGS[@]}"}"

# ═══════════════════════════════════════════
# WORKSPACE & MISSION RESOLUTION
# ═══════════════════════════════════════════

resolve_workspace() {
  if [ -n "$WS_FLAG" ]; then echo "$WS_FLAG"; return; fi
  if [ -n "${MC_WORKSPACE:-}" ]; then echo "$MC_WORKSPACE"; return; fi
  if [ -f ".mc-workspace" ]; then cat .mc-workspace; return; fi
  if [ -f "$CONFIG_DIR/config.json" ]; then
    local val
    val=$(grep -o '"default_workspace":"[^"]*"' "$CONFIG_DIR/config.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [ -n "$val" ]; then echo "$val"; return; fi
  fi
  echo "default"
}

resolve_mission() {
  if [ -n "$MISSION_FLAG" ]; then echo "$MISSION_FLAG"; return; fi
  if [ -n "${MC_MISSION:-}" ]; then echo "$MC_MISSION"; return; fi
  if [ -f "$CONFIG_DIR/config.json" ]; then
    local ws
    ws=$(resolve_workspace)
    # Try to extract workspace-specific default mission from config
    local val
    val=$(python3 -c "
import json,sys
try:
  c=json.load(open('$CONFIG_DIR/config.json'))
  print(c.get('workspaces',{}).get('$ws',{}).get('default_mission',''))
except: pass
" 2>/dev/null || true)
    if [ -n "$val" ]; then echo "$val"; return; fi
  fi
  echo "default"
}

# DB resolution — MC_DB takes priority for backward compat
if [ -n "${MC_DB:-}" ]; then
  DB="$MC_DB"
  WORKSPACE="(custom)"
else
  WORKSPACE=$(resolve_workspace)
  DB="$CONFIG_DIR/workspaces/$WORKSPACE/mission-control.db"
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

# ═══════════════════════════════════════════
# CONFIG HELPERS
# ═══════════════════════════════════════════

ensure_config() {
  if [ ! -f "$CONFIG_DIR/config.json" ]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/config.json" <<'CONF'
{
  "default_workspace": "default",
  "workspaces": {
    "default": {
      "default_mission": "default",
      "created_at": ""
    }
  }
}
CONF
  fi
}

update_config_workspace() {
  local ws_name="$1"
  ensure_config
  python3 -c "
import json, datetime
f='$CONFIG_DIR/config.json'
try:
  c=json.load(open(f))
except: c={'default_workspace':'default','workspaces':{}}
if 'workspaces' not in c: c['workspaces']={}
if '$ws_name' not in c['workspaces']:
  c['workspaces']['$ws_name']={
    'default_mission':'default',
    'created_at': datetime.datetime.now().isoformat()
  }
json.dump(c,open(f,'w'),indent=2)
"
}

# ═══════════════════════════════════════════
# COMMANDS: WORKSPACE MANAGEMENT
# ═══════════════════════════════════════════

cmd_workspace() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    create)
      local name="${1:?Usage: mc workspace create <name>}"
      local ws_dir="$CONFIG_DIR/workspaces/$name"
      if [ -d "$ws_dir" ]; then
        echo -e "${Y}Workspace '$name' already exists${N}"; return 0
      fi
      mkdir -p "$ws_dir"
      # Init DB for this workspace
      sqlite3 "$ws_dir/mission-control.db" < "$SCHEMA_DIR/schema.sql"
      sqlite3 "$ws_dir/mission-control.db" "PRAGMA journal_mode=WAL;" > /dev/null
      update_config_workspace "$name"
      echo -e "${G}Workspace '$name' created${N} → $ws_dir"
      ;;
    list)
      echo -e "${B}═══ WORKSPACES ═══${N}"
      if [ -d "$CONFIG_DIR/workspaces" ]; then
        for d in "$CONFIG_DIR/workspaces"/*/; do
          [ -d "$d" ] || continue
          local ws_name
          ws_name=$(basename "$d")
          local marker=""
          [ "$ws_name" = "$WORKSPACE" ] && marker=" ${C}(current)${N}"
          local db_size=""
          if [ -f "$d/mission-control.db" ]; then
            db_size=$(du -h "$d/mission-control.db" | cut -f1 | tr -d ' ')
          fi
          echo -e "  $ws_name${marker}  ${db_size:+[$db_size]}"
        done
      else
        echo "  (none)"
      fi
      ;;
    current)
      echo -e "Workspace: ${C}$WORKSPACE${N}"
      echo -e "DB:        $DB"
      ;;
    *)
      echo "Usage: mc workspace <create|list|current>"
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
    current)
      ensure_mission_id
      echo -e "Mission:   ${C}$MISSION_NAME${N} (id=$MID)"
      echo -e "Workspace: $WORKSPACE"
      ;;
    *)
      echo "Usage: mc mission <create|list|archive|current>"
      ;;
  esac
}

# ═══════════════════════════════════════════
# COMMANDS: MIGRATION
# ═══════════════════════════════════════════

cmd_migrate() {
  local old_db="$CONFIG_DIR/mission-control.db"
  local new_dir="$CONFIG_DIR/workspaces/default"
  local new_db="$new_dir/mission-control.db"

  if [ ! -f "$old_db" ]; then
    echo -e "${Y}No legacy DB found at $old_db${N}"
    return 0
  fi
  if [ -f "$new_db" ]; then
    echo -e "${Y}Target already exists: $new_db${N}"
    echo "  Remove it first or skip migration."
    return 1
  fi

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

  update_config_workspace "default"

  echo -e "${G}Migration complete${N}"
  echo -e "  Old: $old_db"
  echo -e "  New: $new_db"
  echo -e "  ${Y}Old DB kept as backup. Remove manually when ready.${N}"
}

# ═══════════════════════════════════════════
# COMMANDS: TASKS
# ═══════════════════════════════════════════

cmd_init() {
  mkdir -p "$(dirname "$DB")"
  sqlite3 "$DB" < "$SCHEMA_DIR/schema.sql"
  sqlite3 "$DB" "PRAGMA journal_mode=WAL;" > /dev/null
  [[ "$WORKSPACE" != "(custom)" ]] && update_config_workspace "$WORKSPACE"
  echo -e "${G}Initialized${N} $DB (workspace: $WORKSPACE)"
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
  ensure_mission_id
  local subject="" desc="" priority=0 assignee=""
  subject="${1:?Usage: mc add \"Subject\" [-d desc] [-p 0|1|2] [--for agent]}"
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d) desc="$2"; shift 2;;
      -p) priority="$2"; shift 2;;
      --for) assignee="$2"; shift 2;;
      *) shift;;
    esac
  done
  local status="pending"
  [[ -n "$assignee" ]] && status="claimed"
  local id
  id=$(sql "INSERT INTO tasks(mission_id,subject,description,status,owner,created_by,priority,claimed_at)
    VALUES($MID,'$(echo "$subject" | sed "s/'/''/g")','$(echo "$desc" | sed "s/'/''/g")','$status','$assignee','$AGENT',$priority,$([ -n "$assignee" ] && echo "datetime('now')" || echo "NULL"))
    RETURNING id;")
  log_activity "task_created" "task" "$id" "$subject"
  echo -e "${G}#$id${N} $subject${assignee:+ → $assignee}"
}

cmd_list() {
  ensure_mission_id
  local where="mission_id=$MID"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) where="$where AND status='$2'"; shift 2;;
      --owner) where="$where AND owner='$2'"; shift 2;;
      --mine) where="$where AND owner='$AGENT'"; shift;;
      *) shift;;
    esac
  done
  sql_col "SELECT id, subject,
    CASE status WHEN 'done' THEN '✓' WHEN 'in_progress' THEN '▶' WHEN 'claimed' THEN '◉' WHEN 'blocked' THEN '✗' WHEN 'review' THEN '⟳' ELSE '○' END || ' ' || status AS st,
    COALESCE(owner,'-') AS owner,
    CASE priority WHEN 2 THEN '!!!' WHEN 1 THEN '!' ELSE '' END AS pri
    FROM tasks WHERE $where ORDER BY priority DESC, id;"
}

cmd_claim() {
  ensure_mission_id
  local id="${1:?Usage: mc claim <id>}"
  local current
  current=$(sql "SELECT owner FROM tasks WHERE id=$id AND mission_id=$MID;")
  if [[ -n "$current" && "$current" != "$AGENT" ]]; then
    echo -e "${R}Already claimed by $current${N}"; return 1
  fi
  sql "UPDATE tasks SET owner='$AGENT', status='claimed', claimed_at=datetime('now'), updated_at=datetime('now') WHERE id=$id AND mission_id=$MID;"
  log_activity "task_claimed" "task" "$id" ""
  echo -e "${G}Claimed #$id${N}"
}

cmd_start() {
  ensure_mission_id
  local id="${1:?Usage: mc start <id>}"
  sql "UPDATE tasks SET status='in_progress', updated_at=datetime('now') WHERE id=$id AND mission_id=$MID AND owner='$AGENT';"
  sql "UPDATE agents SET status='busy' WHERE name='$AGENT';"
  log_activity "task_started" "task" "$id" ""
  echo -e "${C}▶ Working on #$id${N}"
}

cmd_done() {
  ensure_mission_id
  local id="${1:?Usage: mc done <id> [-m note]}" note=""
  shift
  while [[ $# -gt 0 ]]; do case "$1" in -m) note="$2"; shift 2;; *) shift;; esac; done
  sql "UPDATE tasks SET status='done', completed_at=datetime('now'), updated_at=datetime('now') WHERE id=$id AND mission_id=$MID;"
  sql "UPDATE agents SET status='idle' WHERE name='$AGENT';"
  log_activity "task_completed" "task" "$id" "$(echo "$note" | sed "s/'/''/g")"
  [[ -n "$note" ]] && sql "INSERT INTO messages(mission_id,from_agent,task_id,body,msg_type) VALUES($MID,'$AGENT',$id,'$(echo "$note" | sed "s/'/''/g")','status');"
  echo -e "${G}✓ Done #$id${N}${note:+ — $note}"
}

cmd_block() {
  ensure_mission_id
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
  echo -e "${B}═══ MISSION CONTROL ═══${N}  $(date '+%H:%M')  agent: ${C}$AGENT${N}"
  echo -e "  workspace: ${C}$WORKSPACE${N}  mission: ${C}$MISSION_NAME${N}"
  echo ""
  for status in pending claimed in_progress review blocked done; do
    local count
    count=$(sql "SELECT COUNT(*) FROM tasks WHERE status='$status' AND mission_id=$MID;")
    [[ "$count" -eq 0 ]] && continue
    local icon
    case $status in pending) icon="○";; claimed) icon="◉";; in_progress) icon="▶";; review) icon="⟳";; blocked) icon="✗";; done) icon="✓";; esac
    echo -e "${B}── $icon $status ($count) ──${N}"
    sql "SELECT '  #' || id || ' ' || subject || CASE WHEN owner IS NOT NULL THEN ' [' || owner || ']' ELSE '' END FROM tasks WHERE status='$status' AND mission_id=$MID ORDER BY priority DESC, id LIMIT 10;"
    echo ""
  done
}

# ═══════════════════════════════════════════
# COMMANDS: MESSAGES
# ═══════════════════════════════════════════

cmd_msg() {
  ensure_mission_id
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
  ensure_mission_id
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
  echo -e "  workspace: ${C}$WORKSPACE${N}  mission: ${C}$MISSION_NAME${N}"
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
  echo -e "Workspace: ${C}$WORKSPACE${N}"
  echo -e "Mission:   ${C}$MISSION_NAME${N}"
  echo -e "DB:        $DB"
  local role
  role=$(sql "SELECT role FROM agents WHERE name='$AGENT';" 2>/dev/null || echo "unregistered")
  echo -e "Role:      ${role:-unregistered}"
}

cmd_help() {
  cat <<'EOF'
Mission Control v0.2 — Coordination for OpenClaw agent fleets

USAGE: mc [-w workspace] [-m mission] <command> [args]

TASKS:
  add "Subject" [-d desc] [-p 0|1|2] [--for agent]   Create task
  list [--status S] [--owner A] [--mine]              List tasks
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

WORKSPACE:
  workspace create <name>                              Create workspace
  workspace list                                       List workspaces
  workspace current                                    Show current

MISSION:
  mission create <name> [-d "description"]             Create mission
  mission list                                         List missions
  mission archive <name>                               Archive mission
  mission current                                      Show current

MIGRATION:
  migrate                                              Migrate legacy DB

GLOBAL FLAGS:
  -w, --workspace <name>   Target workspace
  -m, --mission <name>     Target mission

ENV:
  MC_AGENT       Your agent name (default: $USER)
  MC_WORKSPACE   Workspace name (default: "default")
  MC_MISSION     Mission name (default: "default")
  MC_DB          Direct DB path (overrides workspace resolution)

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
  init|help|-h|--help|workspace|migrate) ;;
  *)
    if [[ ! -f "$DB" ]]; then
      echo -e "${Y}No database found at $DB${N}" >&2
      echo -e "Run: mc init${WS_FLAG:+ -w $WS_FLAG}" >&2
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
  workspace) shift; cmd_workspace "$@" ;;
  mission)   shift; cmd_mission "$@" ;;
  migrate)   cmd_migrate ;;
  help|-h|--help) cmd_help ;;
  *)         echo "Unknown: $1"; cmd_help ;;
esac
