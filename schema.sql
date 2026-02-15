-- Mission Control Schema v0.2
-- Shared coordination layer for OpenClaw agent fleets
-- Supports multi-mission workspaces

-- ═══════════════════════════════════════════
-- MISSIONS
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS missions (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  status      TEXT DEFAULT 'active'
                CHECK(status IN ('active','archived','completed')),
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now'))
);

INSERT OR IGNORE INTO missions(id, name, description) VALUES(1, 'default', 'Default mission');

-- ═══════════════════════════════════════════
-- TASKS
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS tasks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  mission_id  INTEGER NOT NULL DEFAULT 1 REFERENCES missions(id),
  subject     TEXT NOT NULL,
  description TEXT,
  status      TEXT DEFAULT 'pending'
                CHECK(status IN ('pending','claimed','in_progress','blocked','review','done','cancelled')),
  owner       TEXT,
  created_by  TEXT,
  priority    INTEGER DEFAULT 0,
  blocks      TEXT DEFAULT '[]',
  blocked_by  TEXT DEFAULT '[]',
  tags        TEXT DEFAULT '[]',
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now')),
  claimed_at  TEXT,
  completed_at TEXT
);

-- ═══════════════════════════════════════════
-- MESSAGES
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS messages (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  mission_id  INTEGER REFERENCES missions(id),
  from_agent  TEXT NOT NULL,
  to_agent    TEXT,
  task_id     INTEGER REFERENCES tasks(id),
  body        TEXT NOT NULL,
  msg_type    TEXT DEFAULT 'comment'
                CHECK(msg_type IN ('comment','status','handoff','question','answer','alert')),
  created_at  TEXT DEFAULT (datetime('now')),
  read_at     TEXT
);

-- ═══════════════════════════════════════════
-- AGENTS (workspace-shared, no mission_id)
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS agents (
  name        TEXT PRIMARY KEY,
  role        TEXT,
  last_seen   TEXT,
  status      TEXT DEFAULT 'idle'
                CHECK(status IN ('idle','busy','offline')),
  session_id  TEXT,
  registered_at TEXT DEFAULT (datetime('now'))
);

-- ═══════════════════════════════════════════
-- ACTIVITY
-- ═══════════════════════════════════════════

CREATE TABLE IF NOT EXISTS activity (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  mission_id  INTEGER REFERENCES missions(id),
  agent       TEXT,
  action      TEXT NOT NULL,
  target_type TEXT,
  target_id   INTEGER,
  detail      TEXT,
  created_at  TEXT DEFAULT (datetime('now'))
);

-- ═══════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_owner ON tasks(owner);
CREATE INDEX IF NOT EXISTS idx_tasks_mission ON tasks(mission_id);
CREATE INDEX IF NOT EXISTS idx_messages_to ON messages(to_agent);
CREATE INDEX IF NOT EXISTS idx_messages_unread ON messages(to_agent, read_at);
CREATE INDEX IF NOT EXISTS idx_messages_mission ON messages(mission_id);
CREATE INDEX IF NOT EXISTS idx_activity_time ON activity(created_at);
CREATE INDEX IF NOT EXISTS idx_activity_mission ON activity(mission_id);
