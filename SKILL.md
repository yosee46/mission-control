# Mission Control v0.3

Shared coordination layer for OpenClaw agent fleets. Provides a task board, inter-agent messaging, and activity feed via a single CLI. Supports projects (physical DB isolation), multi-mission (logical task isolation), and persistent orchestration for long-running missions.

## Setup

Run `mc init` to create the database. Set your identity: `export MC_AGENT=your-name`

For multiple projects, create separate projects: `mc project create my-project`

### OMOS (Orchestrated Team Setup)

For automated team creation, use the `setup_mission` tool:

```bash
setup_mission <project> <mission> "<goal>" --roles role1,role2,...

# With dynamic role specializations
setup_mission <project> <mission> "<goal>" --roles analyst,writer \
  --role-config roles.json

# With profile
setup_mission <project> <mission> "<goal>" --roles role1,role2,... --profile <name>
```

This creates: MC project + mission, openclaw agents with AGENTS.md, MC fleet registration, and cron jobs — all in one command.

**Dynamic Role Composition:** Use `--role-config roles.json` to define custom role descriptions and specializations. The architect agent can generate this file during mission planning to create optimally specialized teams. Without `--role-config`, agents use builtin descriptions.

Agents are named `{project}-{mission}-{role}` (e.g., `ec-site-prototype-coder`). Each mission gets its own agents — agents are never reused across missions.

## Operational Rhythm

Every agent should follow this pattern:

1. **On startup:** `mc checkin` (registers presence)
2. **Every 10-15 min:** `mc checkin` via cron (heartbeat)
3. **Before work:** `mc inbox --unread` (check messages), `mc list --status pending` (find work)
4. **Claim work:** `mc claim <id>` then `mc start <id>`
5. **During work:** `mc msg <agent> "update" --task <id>` (coordinate)
6. **After work:** `mc done <id> -m "what I did"` then check for next task

## Decision Tree

| Situation | Command |
|-----------|---------|
| New idea/task | `mc add "Subject" -d "Details"` |
| Want to work | `mc list --status pending` then `mc claim <id>` |
| See all tasks | `mc list --all` |
| Stuck/blocked | `mc msg <lead> "Blocked on X" --task <id> --type question` |
| Finished | `mc done <id> -m "Result"` |
| Need review | `mc msg <reviewer> "Ready" --task <id> --type handoff` |
| Catching up | `mc feed --last 20` or `mc summary` |
| New project | `mc project create project-name` |
| Separate workstream | `mc mission create "feature-x" -d "Feature X work"` |
| Work in specific context | `mc -p project -m feature-x list` |
| Build a team | `setup_mission project mission "goal" --roles researcher,coder,reviewer` |
| Long-running mission | `setup_mission project mission "goal" --roles coder --monitor` (adds architect monitoring) |
| Pause mission | `mc -p project -m mission mission pause` (pauses + disables crons) |
| Resume mission | `mc -p project -m mission mission resume` (resumes + enables crons) |
| Mid-mission instruction | `mc -p project -m mission mission instruct "change direction"` |
| Check progress | `mc -p project -m mission mission status` |
| Schedule future task | `mc add "Task" --at "2025-04-01 09:00" --for agent` |
| Create checkpoint | `mc add "Review" --type checkpoint --for reviewer` (auto-pauses when done) |
| Cleanup mission | `mc -p project -m mission mission complete` (archives + removes crons/agents/workspaces) |

## Task Statuses

```
pending → claimed → in_progress → review → done
                  ↘ blocked ↗         ↘ cancelled
```

## CLI Reference

### Global Flags
```
mc [-p project] [-m mission] <command> [args]
```

### Tasks
```
mc add "Subject" [-d "description"] [-p 0|1|2] [--for agent] [--type normal|checkpoint] [--at "YYYY-MM-DD HH:MM"]
mc list [--status STATUS] [--owner AGENT] [--mine] [--all]
mc claim <id>
mc start <id>
mc done <id> [-m "note"]
mc block <id> --by <other-id>
mc board
```

### Messages
```
mc msg <agent> "body" [--task <id>] [--type TYPE]
mc broadcast "body"
mc inbox [--unread]
```

### Fleet
```
mc checkin
mc register <name> [--role role]
mc fleet
```

### Feed
```
mc feed [--last N] [--agent NAME]
mc summary
```

### Project
```
mc project create <name>
mc project list
mc project current
```

### Mission
```
mc mission create <name> [-d "description"]
mc mission list
mc mission complete
mc mission archive <name>
mc mission pause                                Pause mission + disable crons
mc mission resume                               Resume mission + enable crons
mc mission instruct "text"                      Set user instructions for agents
mc mission status                               Show mission status & progress
mc mission current
```

### Migration
```
mc migrate    # Migrate legacy DB to default project
```

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `MC_AGENT` | `$USER` | Agent identity |
| `MC_PROJECT` | `default` | Project name (`MC_WORKSPACE` also accepted) |
| `MC_MISSION` | `default` | Mission name |
| `MC_DB` | (auto-resolved) | Direct DB path (overrides project) |
| `OPENCLAW_PROFILE` | (none) | OpenClaw profile name — uses `~/.openclaw-<profile>/` |

### Profile Usage

When using a profile, pass `--profile` to openclaw commands and set `OPENCLAW_PROFILE` for mc/setup_mission:

```bash
# Run mc-architect
openclaw --profile <name> agent --agent mc-architect -m "<mission>"

# mc commands
OPENCLAW_PROFILE=<name> mc -p <project> -m <mission> board

# setup_mission
setup_mission <project> <mission> "<goal>" --roles coder --profile <name>
```
