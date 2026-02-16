# Plan: 単一DB + プロジェクト/ミッション階層化

> **ステータス**: 保留（未実装）
> **作成日**: 2026-02-16

## Context

現状MCは「workspace = プロジェクト単位の物理DB分離」を採用しているが、求める構造は:
- `~/.openclaw-<profile>/mission-control.db` に**単一DB**
- DB内でプロジェクト > ミッション > タスクの論理階層
- cron名は `<project>-<role>` で、プロジェクト単位の管理が可能（既存の命名規則を維持）

現状のcronは `--workspace` オプション無し。プロジェクト/ミッションは `--message` テキスト内の `mc -w <project> -m <mission>` でハードコード。

## 方針

- **workspace概念をproject概念に置き換え**
- **DB**: `$CONFIG_DIR/mission-control.db` 1ファイル（`workspaces/` ディレクトリ廃止）
- **フラグ**: `-p`/`--project` を追加、`-w`/`--workspace` はエイリアスとして残す（テンプレート変更不要）
- **スキーマ**: `projects` テーブル新設、`missions` に `project_id` FK追加

## 変更対象ファイル (7ファイル)

### 1. `schema.sql` — スキーマv0.3

```sql
-- 新設: projects テーブル
CREATE TABLE IF NOT EXISTS projects (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  status      TEXT DEFAULT 'active'
                CHECK(status IN ('active','archived','completed')),
  created_at  TEXT DEFAULT (datetime('now')),
  updated_at  TEXT DEFAULT (datetime('now'))
);
INSERT OR IGNORE INTO projects(id, name, description) VALUES(1, 'default', 'Default project');

-- missions に project_id 追加
CREATE TABLE IF NOT EXISTS missions (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id  INTEGER NOT NULL DEFAULT 1 REFERENCES projects(id),
  name        TEXT NOT NULL,
  ...
  UNIQUE(project_id, name)  -- プロジェクト内でユニーク
);
```

他テーブル（tasks, messages, activity）は変更不要。mission_id経由でproject_idに到達できる。

### 2. `mc` — コア変更

**DB解決の簡素化**（旧: workspacesディレクトリ → 新: 単一ファイル）:
```bash
# 旧
DB="$CONFIG_DIR/workspaces/$WORKSPACE/mission-control.db"

# 新
DB="$CONFIG_DIR/mission-control.db"
```

**フラグ変更**:
- `-w`/`--workspace` → `-p`/`--project` に名称変更（`-w` はエイリアス維持）
- 内部変数: `WS_FLAG` → `PROJECT_FLAG`、`WORKSPACE` → `PROJECT`

**resolve_project()** （旧 resolve_workspace）:
- 解決優先度: `-p` フラグ > `MC_PROJECT` env > `MC_WORKSPACE` env（後方互換） > config.json default > `"default"`

**resolve_mission()**: config.json参照をprojectベースに変更

**cmd_project()** （旧 cmd_workspace）:
- `mc project create <name>`: projects テーブルにINSERT（ディレクトリ作成なし）
- `mc project list`: projects テーブルをSELECT
- `mc project current`: 現在のプロジェクト表示

**cmd_mission()**: project_idスコープを追加
- `mc -p <project> mission create <name>`: project_id付きでINSERT
- `mc -p <project> mission list`: project_idでフィルタ

**cmd_init()**: 単一DB作成に変更（`mkdir -p "$(dirname "$DB")"` のみ）

**resolve_mission_id()**: project_idスコープ追加
```sql
SELECT id FROM missions WHERE name='$name' AND project_id=$PID;
```

**ensure_project_id() 新設**: resolve_mission_id同様のパターン
```bash
PID=""
ensure_project_id() {
  if [ -z "$PID" ]; then
    PID=$(sql "SELECT id FROM projects WHERE name='$PROJECT_NAME';")
    ...
  fi
}
```

**cmd_help()**: workspace → project に用語変更

**cmd_migrate()**: workspaces/ ディレクトリからの移行ロジック更新

### 3. `tools/setup_mission.py`

**変更**:
- `mc -w {project} init` → `mc init` + `mc project create {project}`
- `mc -w {project} mission create` → `mc -p {project} mission create`
- `mc -w {project} -m {mission} ...` → `mc -p {project} -m {mission} ...`（エイリアスがあるので実質 `-w` でも動く）
- サマリー出力の `mc -w` → `mc -p` 更新

**generate_cron_message()**: `mc -w` → `mc -p` 更新

### 4. `agents/architect/AGENTS.md`

- `mc -w <ws>` → `mc -p <project>` に用語変更
- `workspace create` → `project create` に変更
- cleanup手順も更新

### 5. `agents/templates/*.md`

**変更不要**: `-w` がエイリアスとして残るため、テンプレート内の `mc -w {project}` はそのまま動作する。

### 6. `mobile/mc-server.py`

- DB解決: `~/.openclaw/workspaces/{WORKSPACE}/mission-control.db` → `$CONFIG_DIR/mission-control.db`
- `--workspace` → `--project`（`-w` エイリアス維持）
- `OPENCLAW_PROFILE` 環境変数サポート追加
- `MC_PROJECT` env対応（`MC_WORKSPACE` も後方互換で残す）

### 7. `README.md`

- workspace → project の用語変更
- DB構造の説明更新（単一DB）
- `MC_PROJECT` 環境変数追加
- ディレクトリ構造図の `workspaces/` ディレクトリ削除

### config.json 形式変更

```json
{
  "default_project": "default",
  "projects": {
    "default": { "default_mission": "default" }
  }
}
```

## マイグレーション戦略

`mc migrate` コマンドで:
1. 旧 `$CONFIG_DIR/workspaces/*/mission-control.db` を検出
2. 新 `$CONFIG_DIR/mission-control.db` を作成
3. 各旧workspace DBから:
   - workspace名でprojectを作成
   - missions, tasks, messages, activityを project_id付きで移行
4. 旧config.jsonの `default_workspace` → `default_project` に変換

## 検証手順

```bash
# 初期化
OPENCLAW_PROFILE=mission-control mc init
OPENCLAW_PROFILE=mission-control mc project create ec-site

# ミッション・タスク
OPENCLAW_PROFILE=mission-control mc -p ec-site mission create prototype
OPENCLAW_PROFILE=mission-control mc -p ec-site -m prototype add "Test task"
OPENCLAW_PROFILE=mission-control mc -p ec-site -m prototype board

# 後方互換（-w エイリアス）
OPENCLAW_PROFILE=mission-control mc -w ec-site -m prototype list

# setup_mission dry run
OPENCLAW_PROFILE=mission-control python3 tools/setup_mission.py ec-site mvp "test" --roles coder --dry-run

# DB確認（単一ファイル）
ls ~/.openclaw-mission-control/mission-control.db
sqlite3 ~/.openclaw-mission-control/mission-control.db "SELECT * FROM projects;"
```
