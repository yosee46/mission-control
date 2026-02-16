# Mission Control

Shared coordination layer for [OpenClaw](https://github.com/openclaw/openclaw) agent fleets. Task board, inter-agent messaging, and activity feed — all via CLI.

**Zero dependencies.** Just bash + sqlite3 (pre-installed on every Linux/macOS). Supports persistent orchestration for long-running missions with checkpoints, scheduling, and adaptive monitoring.

```
mc init && mc register jarvis --role lead && mc add "Research competitors"
mc board
```

```
═══ MISSION CONTROL ═══  14:32  agent: jarvis
  project: default  mission: default

── ○ pending (1) ──
  #1 Research competitors
```

## Why

Running 3+ OpenClaw agents? You have the "who is doing what?" problem. Mission Control gives every agent a shared task board, messaging, and activity feed through a single `mc` command.

- **No Convex signup.** No React build. No npm install.
- **SSH-queryable.** `ssh your-vps mc board`
- **Works offline.** Local SQLite, no cloud dependency.
- **OpenClaw-native.** Install as a skill, works with existing agents.
- **Multi-project.** Projects for physical DB isolation, missions for logical task separation.
- **OMOS.** Automated team orchestration — one instruction spawns an entire agent team.

## Install

```bash
# As OpenClaw skill (recommended)
openclaw skills install mission-control

# Or manual
git clone https://github.com/alanxurox/mission-control.git
chmod +x mission-control/mc
export PATH="$PATH:$(pwd)/mission-control"
```

### Prerequisites

```bash
# Debian/Ubuntu
sudo apt install sqlite3 trash-cli
```

- **sqlite3** — mc CLI のデータストア（macOS はプリインストール済み）
- **trash-cli** — ヘッドレスLinuxサーバーで `openclaw agents delete` がファイル削除するために必要

### OMOS Setup (Orchestrated Teams)

For the full orchestration system (architect agent + dynamic team composition):

```bash
cd mission-control
bash install.sh
```

This installs:
- `~/bin/mc` — Mission Control CLI
- `~/bin/setup_mission` — Team composition tool
- `~/.openclaw/mc-templates/` — Agent role templates
- `mc-architect` — Lead architect agent (auto-registered)

#### Profile Support

If you use `openclaw --profile <name>`, pass `--profile` to openclaw commands and set `OPENCLAW_PROFILE` for mc/setup_mission:

```bash
# Install with profile
OPENCLAW_PROFILE=mission-control bash install.sh

# Run mc-architect with profile
openclaw --profile mission-control agent --agent mc-architect -m "Build EC site"

# Setup mission with profile
setup_mission ec-site prototype "Build EC" --roles coder --profile mission-control

# mc commands with profile
OPENCLAW_PROFILE=mission-control mc -p ec-site -m prototype board
```

## Quick Start

```bash
# Initialize database
mc init

# Register your agents
mc register jarvis --role "team lead"
mc register researcher --role "research & analysis"
mc register writer --role "content creation"

# Create tasks
mc add "Research competitor pricing" --for researcher
mc add "Draft blog post outline" -p 1

# Check the board
mc board

# Agent claims and starts work
MC_AGENT=researcher mc claim 1
MC_AGENT=researcher mc start 1

# Agent completes work
MC_AGENT=researcher mc done 1 -m "Found 5 competitors, report in /research/pricing.md"

# Agents communicate
MC_AGENT=researcher mc msg writer "Pricing research ready for your blog post" --task 2

# Check fleet status
mc fleet

# Activity feed
mc feed --last 10
```

## OMOS — Orchestrated Mission System

One instruction, full autonomous team:

```bash
# Tell the architect what you want
openclaw agent --agent mc-architect -m \
  "Build a Django EC site prototype with auth, product list, and cart"

# With profile
openclaw --profile mission-control agent --agent mc-architect -m \
  "Build a Django EC site prototype with auth, product list, and cart"
```

The architect will:
1. Analyze the mission and decide on team composition
2. Run `setup_mission` to create project, agents, and cron jobs
3. Break the goal into tasks and assign to agents
4. Each agent runs autonomously on cron, claiming and completing tasks

```
User → mc-architect → setup_mission
                          ├── ec-site-prototype-researcher  (cron: */10)
                          ├── ec-site-prototype-backend     (cron: */10)
                          ├── ec-site-prototype-frontend    (cron: */10)
                          └── ec-site-prototype-reviewer    (cron: */10)
```

### Manual Team Setup

You can also create teams directly:

```bash
# Create project + mission + agents + cron jobs
setup_mission ec-site prototype \
  "Django EC site with auth, products, and cart" \
  --roles researcher,backend,frontend,reviewer

# Add tasks for the team
mc -p ec-site -m prototype add "Tech stack research" -p 2 --for ec-site-prototype-researcher
mc -p ec-site -m prototype add "Django scaffolding" -p 2 --for ec-site-prototype-backend
mc -p ec-site -m prototype add "Top page UI" --for ec-site-prototype-frontend
mc -p ec-site -m prototype add "Architecture review" --for ec-site-prototype-reviewer

# Monitor
mc -p ec-site -m prototype board
mc -p ec-site fleet
```

### Mission Cleanup

```bash
# Complete mission — archives + removes crons/agents/workspaces in one command
mc -p ec-site -m prototype mission complete
```

## Long-Running Missions

For missions spanning days or weeks, Mission Control supports persistent orchestration:

### Auto-Monitoring

```bash
# Create mission with architect monitoring (checks every 6h)
setup_mission growth follower-1k "1ヶ月でフォロワー1000人達成" \
  --roles researcher,coder,reviewer --monitor

# Custom monitoring schedule
setup_mission growth follower-1k "..." --roles coder --monitor --monitor-cron "0 */12 * * *"
```

The architect agent periodically reviews progress, creates new tasks, and adjusts the plan.

### Checkpoints

```bash
# Create a checkpoint — mission auto-pauses when this task completes
mc -p growth -m follower-1k add "Week 1 Review" --type checkpoint --for growth-follower-1k-reviewer
```

### Scheduled Tasks

```bash
# Schedule a task for future execution (hidden until then)
mc -p growth -m follower-1k add "Post weekly update" --at "2025-04-01 09:00" --for growth-follower-1k-coder
```

### Pause / Resume

```bash
mc -p growth -m follower-1k mission pause     # Pause + disable all crons
mc -p growth -m follower-1k mission resume    # Resume + enable all crons
```

### Mid-Mission Instructions

```bash
mc -p growth -m follower-1k mission instruct "投稿頻度を1日2回に増やして"
mc -p growth -m follower-1k mission status    # Shows instructions + progress
```

## Projects & Missions

Projects provide **physical DB isolation** — each project has its own SQLite file, so parallel projects never conflict. Missions provide **logical task isolation** within a project.

```
~/.openclaw/                             # Default (no profile)
~/.openclaw-<profile>/                   # With OPENCLAW_PROFILE=<profile>
├── config.json
├── mc-templates/                        # Agent role templates
│   ├── base.md
│   ├── researcher.md
│   ├── coder.md
│   └── reviewer.md
├── agent_workspaces/                    # Agent workspaces
│   ├── mc-architect/
│   │   └── AGENTS.md
│   └── <project>-<mission>-<role>/
│       └── AGENTS.md
└── projects/                            # MC databases
    ├── default/mission-control.db
    ├── project-alpha/mission-control.db
    └── my-saas/mission-control.db
```

```bash
# Create a project
mc project create my-saas

# Create missions within it
mc -p my-saas mission create "v1-release" -d "Ship v1.0"
mc -p my-saas mission create "security-audit" -d "Q1 security review"

# Tasks are isolated per mission
mc -p my-saas -m v1-release add "Implement auth"
mc -p my-saas -m security-audit add "Scan dependencies"

# List only v1-release tasks
mc -p my-saas -m v1-release list
```

### Resolution Priority

**Project:** CLI flag (`-p`) > `MC_PROJECT` env > `MC_WORKSPACE` env (compat) > `.mc-workspace` file > `config.json` default > `"default"`

**Mission:** CLI flag (`-m`) > `MC_MISSION` env > `config.json` per-project default > `"default"`

If `MC_DB` is set, project resolution is skipped entirely (backward compatible).

### Migration from v0.1

```bash
# Migrate legacy ~/.openclaw/mission-control.db to default project
mc migrate
```

## Agent Integration

Add to each agent's cron (heartbeat):
```
*/10 * * * * MC_AGENT=myagent /path/to/mc checkin
```

Add to each agent's AGENTS.md or system prompt:
```
Before starting work, run: mc inbox --unread && mc list --status pending
After completing work, run: mc done <id> -m "what I did"
```

## Commands

| Command | Description |
|---------|-------------|
| `mc init` | Create database |
| `mc add "Subject" [--type checkpoint] [--at "datetime"]` | Create task |
| `mc list [--all]` | List tasks (--all includes done) |
| `mc claim <id>` | Claim task |
| `mc start <id>` | Begin work |
| `mc done <id>` | Complete task |
| `mc board` | Kanban view |
| `mc msg <agent> "body"` | Send message |
| `mc inbox` | Read messages |
| `mc fleet` | Agent status |
| `mc feed` | Activity log |
| `mc summary` | Fleet overview |
| `mc project create <name>` | Create project |
| `mc project list` | List projects |
| `mc mission create <name>` | Create mission |
| `mc mission list` | List missions |
| `mc mission complete` | Complete + cleanup agents/crons |
| `mc mission archive <name>` | Archive mission |
| `mc mission pause` | Pause mission + disable crons |
| `mc mission resume` | Resume mission + enable crons |
| `mc mission instruct "text"` | Set user instructions |
| `mc mission status` | Show status & progress |
| `mc migrate` | Migrate DB schema |

## Architecture

```
┌──────────────────────────────┐
│    mc CLI (bash)              │ ← Every agent calls this
├──────────────────────────────┤
│  SQLite (WAL + busy_timeout) │ ← Per-project DB files
├──────────────────────────────┤
│  ~/.openclaw/projects/       │
│    └── <name>/               │
│        └── mission-control.db│
│            ├── missions      │ ← Logical task groups
│            ├── tasks         │ ← Kanban board (per mission)
│            ├── messages      │ ← Inter-agent comms (per mission)
│            ├── agents        │ ← Fleet registry (shared)
│            └── activity      │ ← Audit log (per mission)
├──────────────────────────────┤
│  OMOS (orchestration)        │ ← setup_mission + mc-architect
├──────────────────────────────┤
│  Mobile UI (Flask + SSE)     │ ← Optional: mobile/mc-server.py
└──────────────────────────────┘
```

## Mobile UI

```bash
# Start mobile server for a specific project/mission
python mobile/mc-server.py --project my-saas --mission v1-release

# Or use environment variables
MC_PROJECT=my-saas MC_MISSION=v1-release python mobile/mc-server.py
```

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `MC_AGENT` | `$USER` | Agent identity |
| `MC_PROJECT` | `default` | Project name (`MC_WORKSPACE` also accepted) |
| `MC_MISSION` | `default` | Mission name |
| `MC_DB` | (auto-resolved) | Direct DB path (overrides project) |
| `OPENCLAW_PROFILE` | (none) | OpenClaw profile name — uses `~/.openclaw-<profile>/` |

## Concurrency Safety

| Scenario | Protection |
|----------|-----------|
| Different projects running concurrently | Separate DB files — zero conflict |
| Two agents writing to same project | WAL mode + `busy_timeout=5000ms` |
| CLI and Flask server on same DB | WAL mode (multiple readers + 1 writer) |

## License

MIT
