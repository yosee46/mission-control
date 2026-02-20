# OMOS 安定化設計 — 最終合意仕様書

> 3エージェント討論（Alpha: 耐障害性 / Beta: シンプリシティ / Gamma: 可観測性）の合意に基づく設計仕様

---

## 1. 設計の最上位原則

### 原則 1: LLMにやらせることとCLIにやらせることを明確に分離する

| LLM に任せる（テンプレート） | mc CLI に任せる（Python コード） |
|---|---|
| 状況判断（board を見て何をすべきか決める） | Cron Guard の disable/enable |
| タスクの claim/実行/done | Phase 状態の管理と判定 |
| 人間への報告内容の作成 | plan.md の解析とタスク定義の構造化 |
| 異常時のエスカレーション判断 | 実行ログの自動記録 |
| | setup_mission の冪等性 |
| | in_progress タスクの検出 |

### 原則 2: LLM に bash ワンライナーを生成させない

`openclaw cron list --json | python3 -c "..."` パターンをテンプレートから完全に排除する。mc CLI のコマンド1つで同じことを実現する。

### 原則 3: 状態の真実源は1つだけ

plan.md + YAML + phase-state.json のように情報源が増えるたびに不整合リスクが乗算される。Phase 状態は mc CLI が一元管理し、plan.md は人間向けドキュメントとして位置づける。

### 原則 4: テンプレートは短く保つ

テンプレートに1行追加するたびに「本当にこれはLLMに書かせるべきか? CLIコマンドにできないか?」と問い直す。テンプレートの追加は、他の部分の削減を伴わない限り原則として行わない。

### 原則 5: 問題を解決するために新たな問題を作らない

ファイルロック→残骸、セッション状態ファイル→二重管理、YAMLフロントマター→不整合。「問題を解決するために新たな障害点を作る」パターンを拒否する。

---

## 2. 全員一致の合意事項（6点）

| # | 合意事項 | 根拠 | 出典 |
|---|---------|------|------|
| 1 | **Cron Guard の CLI 化** | 13箇所のbashワンライナー → `mc cron-guard` 1コマンドに。セッション障害確率49%の根本原因を除去 | Alpha/Beta/Gamma 全員 |
| 2 | **in_progress タスクの再開ロジック追加** | base.md に3行追加でクラッシュリカバリの最重要ケースをカバー。全員が「見落としていた設計バグ」と認定 | Alpha 提案1 |
| 3 | **LLM の出力を信頼しない** | 複雑なロジックは Python/CLI に移す。テンプレートには状況判断と単純コマンド呼び出しのみ | 全員の設計哲学 |
| 4 | **Phase 管理の簡素化** | brain.md の28%（約60行）を占める Phase 管理 → CLI コマンド5行に置換 | Alpha/Gamma (High), Beta (Low→High に修正) |
| 5 | **setup_mission.py の冪等化** | register_agent に存在確認追加。Python コード修正なので LLM 不確実性の影響なし | Alpha 提案3 |
| 6 | **cron メッセージの最小化** | Single Source of Truth を AGENTS.md に統一。cron 起動メッセージは最小限に | Beta 提案6 |

---

## 3. 対立した論点と解決（7点）

### 3.1 Supervisor 構成

| Agent | 主張 |
|-------|------|
| Alpha | 3分割維持（brain + monitor + escalator）+ 相互監視 |
| Beta | brain 単一統合（コスト67%削減） |
| Gamma | monitor を brain に統合、escalator は独立維持（2エージェント） |

**採用: 2エージェント構成（Gamma 案）**

```
現行:    monitor(観察) + brain(判断) + escalator(通知) = 3エージェント
採用案:  brain(観察+判断) + escalator(通知) = 2エージェント
```

**理由**:
- monitor → brain の伝言ゲーム（最大12時間のレイテンシ）を解消
- brain は既に Step 3 で board/fleet を確認しているため、monitor 機能の統合による認知負荷増加は限定的
- escalator は「brain が壊れても人間に通知が届く」独立安全弁として維持（Beta の完全統合案の致命的リスクを回避）
- API コスト33%削減（完全統合の67%には劣るが、安全弁を維持）

**Alpha の「3分割維持 + 相互監視」を不採用とした理由**:
- 相互監視ロジック自体が新たなワンライナーの追加になる（Beta の批判）
- monitor → brain の伝言ゲーム問題が未解決のまま残る

**Beta の「brain 完全統合」を不採用とした理由**:
- brain がクラッシュした場合、人間への通知経路が全て喪失する（Alpha/Gamma の批判）
- 観察者と行為者の同一化は客観性を失う（Gamma の批判）

### 3.2 plan.md の構造化

| Agent | 主張 |
|-------|------|
| Alpha | Markdown のまま + 安全書き込みパターン |
| Beta | CLI 化で解決（plan.md は人間向けドキュメント） |
| Gamma | YAML フロントマター導入 |

**採用: Markdown のまま + CLI 化（Alpha + Beta 折衷）**

**理由**:
- YAML フロントマターは「LLM に YAML を正確に書かせる」前提であり、「LLM を信頼しない」原則と矛盾（Alpha の批判）
- YAML と Markdown 本文の二重管理で不整合リスク増大（Beta/Alpha の批判）
- mc CLI が plan.md を Python でパースすれば、構造化は CLI 側で実現できる

### 3.3 相互監視

| Agent | 主張 |
|-------|------|
| Alpha | brain ↔ monitor 双方向相互監視 |
| Beta | 不要（統合で解消） |
| Gamma | 限定的（escalator → brain の片方向のみ） |

**採用: 限定的相互監視（Gamma 案ベース）**

- brain → escalator: brain が escalator の cron 状態を確認し、無効なら再有効化
- escalator → brain: escalator が brain の cron 状態を確認し、無効なら再有効化 + 人間に `[BRAIN_DOWN]` 通知
- 実装は `mc cron-guard check` コマンド（CLI 化済み）を使うため、新たなワンライナー不要

### 3.4 Decision Log

| Agent | 主張 |
|-------|------|
| Alpha | 不要（ログは後回し） |
| Beta | コンセプトは有用だが LLM に echo で JSON を書かせるのは脆弱 |
| Gamma | LLM が構造化 JSON を出力 |

**採用: mc CLI が自動記録（Beta の実装方法）**

```python
# mc CLI の内部で、重要なコマンド実行を自動的に jsonl に記録
# mc add, mc done, mc phase propose 等の実行時に自動で decision-log.jsonl に追記
def log_action(project, action_type, detail):
    log_path = config_dir / "projects" / project / "decision-log.jsonl"
    entry = {
        "ts": datetime.utcnow().isoformat() + "Z",
        "agent": os.environ.get("MC_AGENT", "unknown"),
        "cmd": action_type,
        "detail": detail,
    }
    with open(log_path, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
```

- LLM は何もしなくてよい。`mc add` を実行すれば自動的にログが記録される
- JSON の整合性は Python コードが保証する
- テンプレートへの追加はゼロ

### 3.5 ファイルロック

**全員不採用**（Alpha 提案 → Beta/Gamma が却下）

- 新たな障害点（ロックファイル残骸）を作る
- `stat -f %m` が OS 依存（macOS 固有）
- LLM に15行以上の bash スクリプトを毎回正確に生成させることになる
- mc cron-guard で二重実行の根本原因に対処すれば不要

### 3.6 宣言的フローエンジン

**現時点では不採用**（Gamma 提案 → Alpha/Beta が却下）

- openclaw の既存パターンとの乖離が大きい
- 3層デバッグ（YAML + Python エンジン + LLM）の複雑さ
- Phase 管理 CLI 化で十分な制御が得られる
- 長期的な Tier 4 として再評価の余地あり

### 3.7 Phase 管理 CLI 化の優先度

| Agent | 判定 |
|-------|------|
| Alpha | High |
| Beta | Low（将来的に検討）→ 討論後 High に修正 |
| Gamma | High |

**採用: High（即時ではなく Tier 2 で実施）**

- 全員が plan.md 破損リスクを認めている
- brain.md の約60行を15行に削減可能
- CLI 実装に200行程度の工数が必要なため、Tier 1 ではなく Tier 2

---

## 4. 明確に不採用とした提案（8点）

| # | 提案 | 提案者 | 不採用理由 |
|---|------|-------|-----------|
| 1 | ファイルロック | Alpha 提案7 | 新たな障害点。OS 依存。LLM に複雑 bash を書かせる。cron-guard で根本原因に対処 |
| 2 | セッション状態ファイル | Alpha 提案8 | mc list --mine --status in_progress が Single Source of Truth。二重状態管理のリスク |
| 3 | Supervisor 完全統合（1体） | Beta 提案2 | brain が死んだら全機能停止。escalator の独立安全弁が失われる |
| 4 | YAML フロントマター | Gamma 提案2 | LLM に YAML 生成させることへの全員の懸念。Markdown 本文との二重管理 |
| 5 | 宣言的フローエンジン（即時） | Gamma 提案(本体) | openclaw 既存パターンとの乖離。学習コスト。デバッグ困難 |
| 6 | Phase 状態マシン（独立ファイル） | Gamma 提案3 | phase-state.json と plan.md の二重管理。mc phase CLI で代替可能 |
| 7 | 3エージェント分離維持 | Alpha 原案 | monitor → brain の伝言ゲーム（最大12時間遅延）が非効率 |
| 8 | Plan Drift 検知（テンプレートベース） | Gamma 提案4 | 自然言語マッチングの精度問題。mc phase CLI で drift 自体を予防する方が本質的 |

---

## 5. 変更提案の詳細

### Tier 1: 即時実施（工数: 3-4時間）

#### 5.1.1 `mc cron-guard` コマンド追加

**変更対象**: `mc` CLI（約50行追加）

**仕様**:
```bash
mc cron-guard disable <agent-name>   # cron を無効化
mc cron-guard enable <agent-name>    # cron を有効化
mc cron-guard check <agent-name>     # cron の状態を確認（enabled/disabled）
```

**実装方針**:
- `openclaw cron list --json` で cron job を name で検索
- `openclaw cron disable/enable` で操作
- **ベストエフォート**: cron job が見つからない/操作失敗の場合はログ出力して続行（エラー終了しない）
- 環境変数 `OPENCLAW_PROFILE` を自動参照

**テンプレート変更**:

Before（現行、各テンプレートに存在する3行ワンライナー）:
```bash
cron_id=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw --profile "$OPENCLAW_PROFILE" cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled at $(date '+%Y-%m-%d %H:%M:%S') — session started"
```

After:
```bash
mc cron-guard disable {agent_id}
```

**影響範囲**: brain.md, base.md, monitor.md, escalator.md の全 Cron Guard セクション（disable 箇所 × 4 + enable 箇所 × 4 以上）

#### 5.1.2 全テンプレートの Cron Guard 書き換え

**変更対象**: brain.md, base.md, escalator.md（monitor.md は Tier 3 で廃止）

各テンプレートの Step 0（Cron Guard disable）と最終ステップ（Cron Guard enable）を1行コマンドに置換。

**brain.md 例**:
```markdown
### 0. Cron Guard
```bash
mc cron-guard disable {agent_id}
```
If this fails, skip and continue.

...（中略）...

### Final. Re-enable Cron
```bash
mc cron-guard enable {agent_id}
```
```

#### 5.1.3 base.md: in_progress 再開ロジック追加

**変更対象**: `agents/templates/base.md` の Step 3

**Before（現行）**:
```markdown
### 3. Find Work
```bash
mc -p {project} -m {mission} list --mine --status pending
```
```

**After**:
```markdown
### 3. Resume or Find Work

First, check for your own in-progress tasks (from a previous crashed session):
```bash
mc -p {project} -m {mission} list --mine --status in_progress
```

If you have an in_progress task:
- Resume it — check what was already done, continue from where it left off.
- When done: `mc -p {project} -m {mission} done <id> -m "Resumed and completed: ..."`

If no in_progress tasks, check for pending tasks:
```bash
mc -p {project} -m {mission} list --mine --status pending
```

If no assigned tasks, check for unclaimed work:
```bash
mc -p {project} -m {mission} list --status pending
```
```

**設計根拠**: `mc list --mine --status in_progress` が Single Source of Truth。セッション状態ファイル等の二重管理を避ける。

#### 5.1.4 cron メッセージ最小化

**変更対象**: `tools/setup_mission.py`

**Before（現行）**: 各エージェント種別ごとに異なる長文 cron メッセージ

**After**: 全エージェント統一メッセージ

```python
def generate_cron_message(agent_id: str, **kwargs) -> str:
    return (
        f"You are {agent_id}. Read your AGENTS.md and execute your workflow. "
        f"日本語で応答すること。"
    )
```

**設計根拠**: Single Source of Truth を AGENTS.md に統一。cron メッセージと AGENTS.md の齟齬が LLM の混乱を招くリスクを排除。

#### 5.1.5 setup_mission.py の冪等化

**変更対象**: `tools/setup_mission.py` の `register_agent` 関数

**変更内容**:

1. `agent_exists()` / `cron_exists()` ヘルパー関数の追加:
```python
def agent_exists(agent_id: str, oc_profile_flag: str) -> bool:
    """Check if an openclaw agent is already registered."""
    result = run(f"openclaw {oc_profile_flag} agents list",
                 capture=True, check=False)
    return agent_id in (result.stdout or "")

def cron_exists(agent_id: str, oc_profile_flag: str) -> bool:
    """Check if a cron job already exists for this agent."""
    result = run(f"openclaw {oc_profile_flag} cron list --json",
                 capture=True, check=False)
    try:
        jobs = json.loads(result.stdout or "{}").get("jobs", [])
        return any(j.get("name") == agent_id for j in jobs)
    except (json.JSONDecodeError, AttributeError):
        return False
```

2. `register_agent()` の各サブステップに存在確認を追加:
   - workspace: 既に `exist_ok=True` で冪等（変更不要）
   - AGENTS.md: 常に上書き（冪等）
   - openclaw agent: `agent_exists()` で存在確認後、未登録時のみ `agents add`
   - mc fleet: `mc register` は既に冪等（変更不要）
   - cron: `cron_exists()` で存在確認後、未登録時のみ `cron add`

3. `main()` 末尾に最終検証ステップを追加:
```python
# ─── Final Verification ───
print(f"\n[Verify] Checking all agents...")
failed = []
for agent_id in agents_created:
    if not agent_exists(agent_id, oc_profile_flag):
        failed.append(f"{agent_id}: not in openclaw agents")
    if not cron_exists(agent_id, oc_profile_flag):
        failed.append(f"{agent_id}: no cron job")

if failed:
    print(f"\nWARNING: Verification failed:")
    for f in failed:
        print(f"  - {f}")
    print(f"\nRe-run setup_mission (it is idempotent) to fix.")
    sys.exit(1)
else:
    print(f"  All {len(agents_created)} agents verified.")
```

---

### Tier 2: 次イテレーション（工数: 6-8時間）

#### 5.2.1 `mc phase` コマンド群

**変更対象**: `mc` CLI（約200行追加）

**仕様**:
```bash
# Phase 状態確認
mc -p {project} -m {mission} phase status
# 出力例:
# Phase 1: Research — COMPLETE (6/6 done, criteria: met)
# Phase 2: Implementation — IN_PROGRESS (2/5 done)
# Phase 3: Testing — PENDING

# Phase 完了判定 + 次 Phase 提案
mc -p {project} -m {mission} phase advance
# 出力例:
# Phase 2 is not complete (2/5 tasks done)

# plan.md からタスク一括作成
mc -p {project} -m {mission} phase create-tasks <N>
# plan.md の Phase N のタスクを解析して mc add を実行
# 出力例:
# Created task #1: "データモデル設計" for {project}-{mission}-backend [P0]
# Created task #2: "REST API実装" for {project}-{mission}-backend [P0]

# Phase 進行を提案（checkpoint 作成 + mission pause）
mc -p {project} -m {mission} phase propose <N>

# plan.md のアノテーション更新（CLI が安全に書き込み）
mc -p {project} -m {mission} phase annotate
# backup 作成 → タスク状態を反映して plan.md を更新
```

**内部実装**:
- plan.md を Python でパース（`## Phase N` セクション、`- [ ] タスク説明 @role [P0]` 行）
- `@role` → `{project}-{mission}-{role}` の展開を Python コードが正確に実行
- `[P0]`/`[P1]`/`[P2]` → priority 値のマッピングを Python コードが正確に実行
- plan.md への書き込みは `backup → tmp → validate → mv` パターンで安全に実行

#### 5.2.2 plan_parser.py

**変更対象**: `tools/plan_parser.py`（新規、約200行）

plan.md の Markdown パーサー + バリデーター。`mc phase` コマンドの内部モジュール。

```python
@dataclass
class PlanTask:
    description: str
    role: str           # kebab-case role name
    priority: int       # 0, 1, 2
    scheduled_at: str | None  # --at の日時

@dataclass
class PlanPhase:
    number: int
    name: str
    auto: bool
    success_criteria: str
    tasks: list[PlanTask]

@dataclass
class MissionPlan:
    goal: str
    phases: list[PlanPhase]

def parse_plan(plan_path: Path) -> MissionPlan: ...
def validate_plan(plan: MissionPlan, roles: list[str]) -> list[str]: ...
```

**バリデーション項目**:
- ファイル非空
- `## Goal` セクション存在
- `## Phase 1` 存在 AND `Auto: true` 含む
- 各タスクの `@role` が roles リストに含まれる
- priority が 0, 1, 2 のいずれか
- `--at` の日時フォーマットが正しい

#### 5.2.3 brain.md Phase 管理簡素化

**変更対象**: `agents/templates/brain.md` の Step 2.5（約60行 → 約15行）

**After**:
```markdown
### 2.5. Phase Management

```bash
mc -p {project} -m {mission} phase status
```

Based on the output:

- **Phase 1 + Auto: true + no tasks yet** →
  `mc -p {project} -m {mission} phase create-tasks 1`
- **Current phase COMPLETE + next phase exists + NOT proposed** →
  `mc -p {project} -m {mission} phase propose <N>`
  (This creates a checkpoint and pauses the mission. Stop here.)
- **Current phase PROPOSED + mission resumed** →
  `mc -p {project} -m {mission} phase create-tasks <N>`
  Then re-enable assigned agents' crons.
- **All phases COMPLETE** → Create mission completion checkpoint:
  ```bash
  mc -p {project} -m {mission} add "Mission goal achieved — human review" \
    --type checkpoint --for {agent_id}
  ```
  Then claim → start → done this checkpoint.
- **Otherwise** → Proceed to Step 3 (Judge and Act).
```

#### 5.2.4 brain Guardrails セクション追加

**変更対象**: `agents/templates/brain.md`（約10行追加）

```markdown
## Guardrails (MUST follow)

- **Task creation limit**: Create at most 7 tasks per session.
  If more are needed, spread across multiple sessions.
- **Phase discipline**: Do NOT create tasks for Phase N+1 until Phase N is COMPLETE.
- **plan.md is read-only for you**: Never write to plan.md directly.
  Use `mc phase annotate` if status updates are needed.
- **Escalation threshold**: If you are uncertain about any decision,
  create a task for the escalator rather than guessing.
- **No new agents**: Never register new agents or modify cron schedules.
```

#### 5.2.5 自動 Decision Log

**変更対象**: `mc` CLI（約60行追加）

mc CLI の主要コマンド（`add`, `done`, `claim`, `start`, `block`, `phase propose`, `phase create-tasks`）の実行時に、自動的に `decision-log.jsonl` に追記する。

```python
def log_action(project: str, action: str, detail: dict):
    config_dir = resolve_config_dir()
    log_path = config_dir / "projects" / project / "decision-log.jsonl"
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "agent": os.environ.get("MC_AGENT", "unknown"),
        "action": action,
        **detail,
    }
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass  # ログ記録失敗は非致命的
```

**閲覧コマンド**:
```bash
mc -p {project} log [--since "24h"] [--agent brain] [--action task_create]
```

**設計根拠**: LLM に echo で JSON を書かせない。mc CLI が自動記録するため、テンプレートへの追加はゼロ。

---

### Tier 3: 中期（工数: 4-6時間）

#### 5.3.1 Supervisor 部分統合（monitor → brain）

**変更対象**: setup_mission.py, brain.md, escalator.md, monitor.md（廃止）

**setup_mission.py の変更**:
- Supervisor 登録を3 → 2に変更（monitor を削除）
- brain に monitor 由来の cron スケジュールを統合（必要に応じて brain の cron 頻度を調整）

**brain.md に追加する monitor 由来の機能**:

```markdown
### 2. Observe (Board, Fleet, Messages)

```bash
mc -p {project} -m {mission} board
mc -p {project} fleet
mc -p {project} -m {mission} inbox --unread
mc -p {project} -m {mission} mission status
```

Check for:
- **Blocked tasks**: Analyze blocker, create unblocking tasks or reassign
- **Stale tasks** (in_progress > 24h with no updates): Reassign or break down
- **Stale agents** (last_seen > 20min + has tasks): `mc cron-guard enable <agent-id>`
- **All tasks done**: Proceed to Phase Management

Also verify escalator's cron:
```bash
mc cron-guard check {project}-{mission}-escalator
```
If disabled and escalator has pending tasks → `mc cron-guard enable {project}-{mission}-escalator`
```

**escalator.md に追加する brain 監視機能**:

```markdown
### 1.5. Brain Health Check
```bash
mc cron-guard check {project}-{mission}-brain
```

If brain's cron is disabled:
1. Check brain's last_seen via `mc -p {project} fleet`
2. If last_seen > 30 minutes:
   - Re-enable: `mc cron-guard enable {project}-{mission}-brain`
   - Report in session output:
     `[BRAIN_DOWN] brain の cron が無効化されたまま30分以上経過。cron を再有効化しました。`
```

**monitor.md**: Tier 3 完了時に廃止。

#### 5.3.2 mc-architect Step 再番号付け

**変更対象**: `docs/mc-architect-spec.md`, `agents/architect/AGENTS.md`

現行の `Step 3 → 3.5 → 3.7 → 3.8` を連続整数に変更:

| 現行 | 変更後 | 内容 |
|------|-------|------|
| Step 0 | Step 1 | Profile 検出 |
| Step 1 | Step 2 | ミッション分析 |
| Step 2 | Step 3 | チーム設計 |
| Step 3 | Step 4 | plan.md 作成 |
| Step 3.5 | Step 5 | plan.md バリデーション |
| Step 3.7 | Step 6 | ユーザー承認 |
| Step 3.8 | Step 7 | 承認待ち（セッション終了） |
| Step 4 | Step 8 | setup_mission 実行 |
| Step 5 | Step 9 | 完了報告 |
| Step 6 | Step 10 | brain 委任 |

#### 5.3.3 テンプレート DRY 化

**変更対象**: `tools/setup_mission.py` の `safe_render` 関数

共通セクションを setup_mission.py 側で展開する:

```python
COMMON_SECTIONS = {
    "cron_guard_disable": (
        "```bash\n"
        "mc cron-guard disable {agent_id}\n"
        "```\n"
        "If this fails, skip and continue."
    ),
    "cron_guard_enable": (
        "```bash\n"
        "mc cron-guard enable {agent_id}\n"
        "```"
    ),
    "checkin_guard": (
        "```bash\n"
        "mc -p {project} -m {mission} checkin\n"
        "```\n"
        "If PAUSED/COMPLETED/ARCHIVED → `mc cron-guard enable {agent_id}` and stop."
    ),
}
```

テンプレート側:
```markdown
### 0. Cron Guard
{cron_guard_disable}

### 1. Check In
{checkin_guard}
```

---

### Tier 4: 長期（必要に応じて）

| # | 施策 | 判断基準 |
|---|------|---------|
| 1 | `mc plan validate` コマンド | plan.md 破損が頻発する場合 |
| 2 | `mc architect-context` コマンド | architect の状態復元（Step 間でのセッション中断）が問題になった場合 |
| 3 | `mc dashboard` コマンド | ユーザーからの要望に応じて |
| 4 | 宣言的フローエンジン | CLI 化で不十分な場合のみ。Gamma の設計をベースに段階的導入 |

---

## 6. テンプレート行数の予測推移

| ファイル | 現状 | Tier 1 後 | Tier 2 後 | Tier 3 後 |
|---------|------|----------|----------|----------|
| brain.md | 215行 | ~185行 (-14%) | ~125行 (-42%) | ~120行 (-44%) |
| base.md | 104行 | ~80行 (-23%) | ~70行 (-33%) | ~65行 (-37%) |
| monitor.md | 99行 | ~75行 (-24%) | ~70行 (-29%) | **廃止** |
| escalator.md | 99行 | ~75行 (-24%) | ~70行 (-29%) | ~65行 (-34%) |
| **合計** | **517行** | **~415行 (-20%)** | **~335行 (-35%)** | **~250行 (-52%)** |

---

## 7. ファイル変更マトリクス

```
mission-control/
├── mc                              # Tier 1: cron-guard 追加
│                                   # Tier 2: phase, log 追加
│                                   # Tier 2: decision-log 自動記録
│
├── tools/
│   ├── setup_mission.py            # Tier 1: 冪等化, cron メッセージ最小化
│   │                               # Tier 3: monitor 廃止, DRY 化
│   └── plan_parser.py              # Tier 2: 新規（mc phase の内部モジュール）
│
├── agents/
│   ├── architect/
│   │   └── AGENTS.md               # Tier 3: Step 再番号付け
│   └── templates/
│       ├── base.md                 # Tier 1: in_progress 再開, cron-guard CLI 化
│       ├── brain.md                # Tier 1: cron-guard CLI 化
│       │                           # Tier 2: Phase CLI 化, Guardrails 追加
│       │                           # Tier 3: monitor 統合, escalator cron 監視追加
│       ├── escalator.md            # Tier 1: cron-guard CLI 化
│       │                           # Tier 3: brain watchdog 追加
│       └── monitor.md              # Tier 1: cron-guard CLI 化
│                                   # Tier 3: 廃止（brain に統合）
│
└── docs/
    └── mc-architect-spec.md        # Tier 3: Step 再番号付け
```

---

## 8. リカバリーマトリクス

### mc-architect のリカバリー

| 状態 | 失敗パターン | リカバリー |
|------|-------------|-----------|
| Profile 検出 | PROFILE 未設定 | エラーメッセージ → 停止。ユーザーに設定を依頼 |
| ミッション分析 | Slack 情報抽出失敗 | ユーザーに直接質問 |
| plan.md 作成 | バリデーション失敗 | `mc plan validate` の出力に従い修正 → 再バリデーション |
| ユーザー承認 | 修正要求 | plan 修正 → 再バリデーション → 再提示 |
| setup_mission | 1回目失敗 | エラー診断 → 冪等なので即リトライ |
| setup_mission | 2回目失敗 | Slack にエラー詳細を報告 → **停止**（`mc add` フォールバック禁止） |
| 完了報告 | brain 即時起動失敗 | 非致命的。cron が6時間以内に起動。報告に記載 |

### brain のリカバリー

| 状態 | 失敗パターン | リカバリー |
|------|-------------|-----------|
| Cron Guard | disable 失敗 | スキップして続行（ベストエフォート） |
| Check In | mc checkin 失敗 | 3回リトライ → 失敗なら停止（escalator が検知） |
| Observe | board/fleet 取得失敗 | 部分情報で判断。致命的なら停止 |
| Phase 管理 | `mc phase` コマンド失敗 | Phase 管理スキップ → Judge 状態に進む |
| タスク作成 | 個別タスク失敗 | 失敗を記録して次へ。全失敗なら停止 |
| Cron Guard | enable 失敗 | スキップ。escalator が検知して cron 再有効化 |

### escalator のリカバリー

| 状態 | 失敗パターン | リカバリー |
|------|-------------|-----------|
| Cron Guard | disable 失敗 | スキップして続行 |
| Brain Health Check | brain の cron 状態取得失敗 | スキップして通常のタスク処理に進む |
| Slack 通知 | 送信失敗 | リトライ（最大3回）→ 失敗ならセッション出力に記録 |

---

## 9. 実装の前提条件と制約

### 前提条件
- mc CLI は Python/Bash で実装されている（SQLite をバックエンドに使用）
- openclaw CLI が `cron list --json`, `cron disable`, `cron enable` をサポートしている
- 各エージェントのシェルセッションは独立（変数は引き継がれない）
- cron は6時間間隔（設定可能）で起動する

### 制約
- テンプレート変数（`{agent_id}`, `{project}`, `{mission}` 等）は `setup_mission.py` の `safe_render` で展開される
- plan.md のフォーマットは既存の Markdown 形式を維持する（YAML フロントマターは導入しない）
- mc CLI への追加コマンドは既存のサブコマンド体系（`mc -p <project> -m <mission> <command>`）に従う

---

## 10. 討論の経緯と参考文書

### 討論参加エージェント

| エージェント | 設計哲学 | 最重要視する観点 | 主な手段 |
|------------|---------|---------------|---------|
| **Alpha** | ステートマシン + バリデーションゲート | 耐障害性 | テンプレートにガードレールを追加 |
| **Beta** | イベント駆動 + ガードレール + 防御的プログラミング | シンプリシティ | mc CLI にロジックを移しテンプレートを縮小 |
| **Gamma** | 宣言的フロー定義 + 汎用エグゼキューター | 可観測性 | ログ・状態ファイル・検証ステップを追加 |

### 参考文書（docs/debate/）

| ファイル | 内容 |
|---------|------|
| agent-a-proposal.md | Alpha（耐障害性）の初期提案 |
| agent-b-proposal.md | Beta（シンプリシティ）の初期提案 |
| agent-c-proposal.md | Gamma（可観測性）の初期提案 |
| agent-a-critique.md | Alpha による Beta/Gamma への批判的レビュー + 統合提案 |
| agent-b-critique.md | Beta による Alpha/Gamma への批判的レビュー + 統合提案 |
| agent-c-critique.md | Gamma による Alpha/Beta への批判的レビュー + 統合提案 |
| agent-beta-proposal.md | Beta の詳細提案書（反論を踏まえた改訂版） |
| agent-gamma-proposal.md | Gamma の詳細提案書（反論を踏まえた改訂版） |

### 合意形成のプロセス

1. **初期提案**: 各エージェントが独立にコードベースを分析し、設計仮説を提出
2. **批判的レビュー**: 各エージェントが他の2者の提案を批判的に評価
3. **反論と修正**: 批判を受けて各エージェントが提案を改訂
4. **合意点の抽出**: 3者の提案から一致する点（6点）を抽出
5. **対立点の解決**: 投票ではなく、技術的根拠に基づく最適解の選択（7点）
6. **不採用判断**: 明確な技術的理由による不採用決定（8点）
7. **統合仕様の策定**: 合意点 + 解決済み対立点を統合した段階的実装計画

---

## 11. 変更の要約（Diff サマリー）

### mc CLI
- **追加**: `mc cron-guard disable|enable|check` サブコマンド（~50行）
- **追加**: `mc phase status|advance|create-tasks|propose|annotate` サブコマンド（~200行）
- **追加**: `mc log` サブコマンド（~30行）
- **追加**: 主要コマンド内への `log_action()` 呼び出し（~60行）

### setup_mission.py
- **変更**: `register_agent()` に冪等性チェック追加
- **追加**: `agent_exists()`, `cron_exists()` ヘルパー関数
- **追加**: `main()` 末尾に最終検証ステップ
- **変更**: `generate_cron_message()` を全エージェント統一メッセージに
- **変更**: Supervisor 登録を3 → 2に（monitor 削除）
- **追加**: COMMON_SECTIONS による DRY 化

### agents/templates/brain.md
- **変更**: Cron Guard ワンライナー → `mc cron-guard` 1行コマンド
- **変更**: Step 2.5 Phase 管理（~60行 → ~15行）
- **追加**: Guardrails セクション（~10行）
- **追加**: Observe セクション（monitor 由来の board/fleet 確認）
- **追加**: escalator cron 監視（1行）

### agents/templates/base.md
- **変更**: Cron Guard ワンライナー → `mc cron-guard` 1行コマンド
- **変更**: Step 3 に in_progress 再開ロジック追加

### agents/templates/escalator.md
- **変更**: Cron Guard ワンライナー → `mc cron-guard` 1行コマンド
- **追加**: Brain Health Check セクション

### agents/templates/monitor.md
- **Tier 1**: Cron Guard CLI 化のみ
- **Tier 3**: 廃止（brain に統合）

### tools/plan_parser.py（新規）
- plan.md の Markdown パーサー + バリデーター（~200行）

### docs/mc-architect-spec.md
- **変更**: Step 再番号付け（3.x → 連続整数）
