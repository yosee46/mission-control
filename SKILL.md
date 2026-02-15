# Mission Control

Shared coordination layer for OpenClaw agent fleets. Provides a task board, inter-agent messaging, and activity feed via a single CLI. Supports workspaces (physical DB isolation) and multi-mission (logical task isolation).

## Setup

Run `mc init` to create the database. Set your identity: `export MC_AGENT=your-name`

For multiple projects, create separate workspaces: `mc workspace create my-project`

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
| Stuck/blocked | `mc msg <lead> "Blocked on X" --task <id> --type question` |
| Finished | `mc done <id> -m "Result"` |
| Need review | `mc msg <reviewer> "Ready" --task <id> --type handoff` |
| Catching up | `mc feed --last 20` or `mc summary` |
| New project | `mc workspace create project-name` |
| Separate workstream | `mc mission create "feature-x" -d "Feature X work"` |
| Work in specific context | `mc -w project -m feature-x list` |

## Task Statuses

```
pending → claimed → in_progress → review → done
                  ↘ blocked ↗         ↘ cancelled
```

## CLI Reference

### Global Flags
```
mc [-w workspace] [-m mission] <command> [args]
```

### Tasks
```
mc add "Subject" [-d "description"] [-p 0|1|2] [--for agent]
mc list [--status STATUS] [--owner AGENT] [--mine]
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

### Workspace
```
mc workspace create <name>
mc workspace list
mc workspace current
```

### Mission
```
mc mission create <name> [-d "description"]
mc mission list
mc mission archive <name>
mc mission current
```

### Migration
```
mc migrate    # Migrate legacy DB to default workspace
```

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `MC_AGENT` | `$USER` | Agent identity |
| `MC_WORKSPACE` | `default` | Workspace name |
| `MC_MISSION` | `default` | Mission name |
| `MC_DB` | (auto-resolved) | Direct DB path (overrides workspace) |
