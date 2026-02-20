# Agent C: 可観測性・制御フロー仮説

## 仮説

現在の OMOS は「fire and forget」型のアーキテクチャであり、各エージェントの判断履歴・実行状態をリアルタイムに追跡する仕組みが欠如している。また、mc-architect が設計した plan.md を brain が自然言語パースに依存して解釈するため、意図の伝達に構造的な保証がなく、Phase 遷移・タスク生成の正確性が LLM の解釈精度に完全に依存している。

---

## 現状の問題点

### 1. 実行トレーサビリティの欠如

**問題**: エージェントの判断履歴が揮発性で、事後追跡が不可能。

- brain テンプレート (brain.md) の Step 5 「Judge and Act」では、brain が「何を判断したか」「なぜその判断をしたか」を記録する仕組みがない。brain は board を見て inbox を読み、判断を下してタスクを作成するが、その **判断の根拠** はセッションログに埋もれ、構造化されていない。
- 仕様書 Section 7 の cron メッセージは `--announce --channel slack` で Slack に通知するが、これはセッション完了時の **要約** であり、判断過程の詳細ではない。
- worker エージェント (base.md) の `done` コマンドでは `-m "Brief description"` を書くが、これは任意テキストであり、**何を試みて何が失敗したか** のような構造化された実行ログではない。
- monitor (monitor.md) は board と fleet を観測してアラートを送るが、**monitor 自身の観測結果の履歴** は保存されない。次回の monitor 起動時に前回何を報告したか分からない。

**影響**: ミッション失敗時の根本原因分析が困難。「なぜ brain はこのタスクを作ったのか」「なぜ worker はこの判断をしたのか」が追跡できない。

### 2. 人間の介入ポイントの不足

**問題**: ミッション実行中に人間が状況を把握し、軌道修正する手段が限定的。

- 仕様書 Section 11 では `mc board`, `mc fleet`, `mc plan show` が人間向けコマンドとして提供されているが、これらは **静的スナップショット** であり、「今 brain が何を考えているか」「次の cron 起動で何が起きるか」は分からない。
- `mc mission instruct` で指示を送れるが、brain がこれを読むのは **次の cron サイクル**（デフォルト6時間後）。緊急の軌道修正に対応できない。
- checkpoint による pause/resume は Phase 境界でのみ機能する。Phase **内** での介入手段（特定タスクの中止、priority 変更、タスク追加）が人間に対して明文化されていない。
- escalator (escalator.md) は AI→人間の一方向チャネルとして設計されているが、**人間→AI** の能動的介入パス（人間が自発的にミッションに介入するフロー）が体系化されていない。`mc mission instruct` は存在するが、それが brain にいつ届くか、どう解釈されるかの保証がない。

**影響**: 人間は「ミッションを起動して結果を待つ」しかできず、進行中の問題に気づいても迅速に対処できない。

### 3. plan.md の解釈保証の欠如

**問題**: brain が plan.md を正しくパースし、意図通りのタスクを作成する構造的保証がない。

- plan.md のフォーマット（仕様書 Step 3.7）は Markdown ベースの自然言語であり、`- [ ] タスク説明 @role [P0]` のようなパターンを LLM が正しく解釈することに依存している。
- brain テンプレートの Step 2.5 C-2「CREATE」では、plan.md の各 `- [ ]` タスクを `mc add` コマンドに変換するが、以下の解釈エラーが起きうる:
  - `@role` から `{project}-{mission}-{role}` への展開ミス
  - `[P0]` / `[P1]` の priority マッピングミス
  - `--at "datetime"` の日時フォーマットミス
  - `--type checkpoint` の見落とし
  - タスク説明の切り出し位置のずれ（`@role` や `[P0]` をタスク説明に含めてしまう等）
- brain テンプレートの Step 2.5 B「Determine Current Phase」では、「match against plan phases by comparing task subjects with plan tasks」という **文字列マッチング** で Phase 判定を行う。タスク件名が brain によって微妙に変更された場合、Phase の完了判定が狂う。
- plan.md 内の Success Criteria は自然言語で記述されるため、brain が「基準を満たしたか」を正しく判定できるかは不確定。

**影響**: architect が意図した通りのタスクが作られない可能性があり、Phase 進行が計画と乖離する。

### 4. Phase 遷移の可視化不足

**問題**: 現在どの Phase にいるか、次に何が起きるかが人間にとって不透明。

- plan.md の更新は brain が行うが（Step 2.5 A「Annotate Progress」）、brain が plan.md を正しく更新する保証がない。brain が `cat > "$(mc -p ... plan path)" << 'PLAN_EOF'` で plan 全体を書き換えるため、**誤って内容を壊すリスク** がある。
- Phase の状態（未着手 / 進行中 / PROPOSED / 完了）は plan.md 内の emoji（🔄, ✅）やテキストマーカー（`[PROPOSED]`）で管理される。これは **構造化データではなく、LLM が Markdown を編集することに依存** している。
- `mc board` は個別タスクの状態を表示するが、**Phase レベルの進捗** は表示しない。人間が Phase 進捗を知るには `mc plan show` で plan.md を読み、brain のアノテーションを解釈する必要がある。
- 仕様書には Phase 遷移のイベントログ（「Phase 1 完了、Phase 2 PROPOSED at 2026-02-20 15:00」等）を記録する仕組みがない。

**影響**: 人間は plan.md を毎回読まないと進捗が分からない。Phase 遷移の履歴も残らない。

### 5. 異常検知と通知の不足

**問題**: 想定外の動作を検知・通知するメカニズムが弱い。

- monitor (monitor.md) は「blocked tasks」「stale tasks」「all done」「stale cron」の4パターンのみを検知する。以下の異常は検知対象外:
  - **plan にないタスクの作成**: brain が plan.md に記載のないタスクを作成しても誰も検知しない
  - **priority の逸脱**: plan では P0 のタスクを brain が P2 で作成しても検知されない
  - **Phase 順序の違反**: brain が Phase 2 のタスクを Phase 1 完了前に作成しても検知されない
  - **タスクの過剰作成**: brain が1回の起動で大量のタスクを作成しても制限がない
  - **plan.md の不正な変更**: brain が plan.md の Goal や Phase 順序を書き換えても検知されない
- escalator は **受動的** であり、タスクが割り当てられなければ動作しない。システム全体の異常を能動的に検知する役割はない。

**影響**: brain の誤動作がサイレントに進行し、人間が気づいた時には手遅れになる。

### 6. mc-architect → brain の引き継ぎギャップ

**問題**: architect が設計した意図が brain に正確に伝わる保証がない。

- architect と brain の間の **唯一の引き継ぎ手段は plan.md ファイル** である（仕様書 Step 5）。architect のセッションは plan.md を作成した時点で終了し、brain は独立したセッションとして起動する。
- plan.md には architect の **設計意図**（なぜこの Phase 順序なのか、なぜこの role にこのタスクを割り当てたのか、依存関係の背景等）が記載されない。plan.md は「何をするか」のリストであり、「なぜそうするか」の情報が欠落している。
- brain テンプレートには「plan の意図を理解する」ための明示的なステップがない。brain は plan.md を読んでタスクを機械的に作成するが、plan の背景にある設計判断を理解しているわけではない。
- `--brain-policy` (setup_mission.py L413-414) で追加ポリシーを渡せるが、これは plan.md とは別のチャネルであり、plan の設計意図を伝える仕組みとしては不十分。
- architect が plan を承認後に brain を即時起動する（仕様書 Step 5）が、brain が plan を誤解した場合のフィードバックループがない。brain が作成したタスクを architect がレビューする仕組みがない（architect のセッションは既に終了している）。

**影響**: architect の設計意図と brain の実行が乖離し、ミッションが意図しない方向に進む。

---

## 改善提案

### 提案 1: 構造化された実行ログ（Decision Log）の導入

**対象問題**: #1 実行トレーサビリティ、#5 異常検知

brain と monitor の各セッションで構造化された判断ログを記録する。

**実装案**: `{config_dir}/projects/{project}/decision-log.jsonl` を導入。

```jsonl
{"ts":"2026-02-20T15:00:00Z","agent":"proj-v1-brain","type":"phase_advance","phase":"Phase 2","reason":"Phase 1 all tasks done, criteria met","tasks_created":["#12","#13"]}
{"ts":"2026-02-20T15:01:00Z","agent":"proj-v1-brain","type":"task_create","task_id":"#12","subject":"API実装","for":"proj-v1-backend","priority":0,"plan_ref":"Phase 2, Task 1"}
{"ts":"2026-02-20T21:00:00Z","agent":"proj-v1-monitor","type":"observation","stale_tasks":["#12"],"blocked_tasks":[],"fleet_status":{"backend":"active","frontend":"idle"}}
```

**brain.md への変更箇所** (Step 5 の末尾に追加):

```markdown
### 5.5. Decision Logging

After every judgment action in Step 5, append a log entry:
\```bash
echo '{"ts":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'","agent":"{agent_id}","type":"<action_type>","detail":"<brief_description>"}' >> "{config_dir}/projects/{project}/decision-log.jsonl"
\```

Action types: `task_create`, `task_reassign`, `phase_advance`, `phase_propose`, `escalation`, `user_instruction`, `remediation`, `checkpoint`
```

**monitor.md への変更箇所** (Step 5 の末尾に追加):

```markdown
### 5.5. Observation Logging

After completing observations in Step 5, append a summary:
\```bash
echo '{"ts":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'","agent":"{agent_id}","type":"observation","blocked":[],"stale":[],"recovered":[],"notes":"<summary>"}' >> "{config_dir}/projects/{project}/decision-log.jsonl"
\```
```

**新規 mc コマンド案**:
```bash
mc -p <project> -m <mission> log [--since "1h"] [--agent <agent>] [--type <type>]
```

### 提案 2: plan.md の機械可読フロントマター導入

**対象問題**: #3 plan.md の解釈保証、#6 引き継ぎギャップ

plan.md の先頭に YAML フロントマターを追加し、タスク定義を構造化する。brain は自然言語パースではなくこのフロントマターを参照してタスクを作成する。

**plan.md 新フォーマット案**:

```markdown
---
version: 1
goal: "Django EC サイトの MVP 構築"
design_intent: |
  Phase 1 でデータモデルとAPIを先に固め、Phase 2 でフロントエンドを構築する。
  API ファーストにすることで、将来のモバイル対応を見据える。
agents:
  backend: "proj-v1-backend"
  frontend: "proj-v1-frontend"
  reviewer: "proj-v1-reviewer"
phases:
  - name: "API設計・実装"
    auto: true
    timeline: "Day 0-2"
    success_criteria:
      - "全APIエンドポイントがテストパス"
      - "OpenAPI specが生成されている"
    tasks:
      - subject: "データモデル設計とマイグレーション作成"
        for: backend
        priority: 0
      - subject: "REST APIエンドポイント実装"
        for: backend
        priority: 0
      - subject: "API テスト作成"
        for: backend
        priority: 1
      - subject: "API 設計レビュー"
        for: reviewer
        priority: 1
        type: checkpoint
  - name: "フロントエンド実装"
    timeline: "Day 3-5"
    tasks:
      - subject: "テンプレート・CSS実装"
        for: frontend
        priority: 0
      - subject: "API連携実装"
        for: frontend
        priority: 1
---

# Mission Plan: prototype
(以下、人間向けの可読形式は維持。brain はフロントマターを優先参照)
```

**brain.md への変更箇所** (Step 2.5 に追加):

```markdown
#### Plan Parsing Priority

1. plan.md に YAML フロントマター (`---` で囲まれたブロック) が存在する場合、
   タスク作成にはフロントマターの `phases[].tasks[]` を使用する。
2. フロントマターがない場合は、従来の Markdown パースにフォールバックする。
3. `design_intent` フィールドが存在する場合、Phase 遷移判断時にこの意図を考慮する。
```

**setup_mission.py への変更**: `--plan` で渡されたファイルのフロントマターをバリデーションする関数を追加。

```python
def validate_plan(plan_path: str, roles: list[str], project: str, mission: str) -> list[str]:
    """Validate plan.md frontmatter against mission configuration. Returns list of warnings."""
    warnings = []
    content = Path(plan_path).read_text()

    # Extract YAML frontmatter
    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            import yaml
            try:
                meta = yaml.safe_load(parts[1])
                # Validate agent references
                for phase in meta.get("phases", []):
                    for task in phase.get("tasks", []):
                        task_role = task.get("for", "")
                        if task_role not in roles:
                            warnings.append(f"Task '{task['subject']}' references unknown role '{task_role}'")
                # Validate priorities
                for phase in meta.get("phases", []):
                    for task in phase.get("tasks", []):
                        p = task.get("priority")
                        if p is not None and p not in [0, 1, 2]:
                            warnings.append(f"Task '{task['subject']}' has invalid priority {p}")
            except Exception as e:
                warnings.append(f"YAML frontmatter parse error: {e}")
    return warnings
```

### 提案 3: Phase 状態マシンの導入

**対象問題**: #4 Phase 遷移の可視化、#5 異常検知

Phase の状態を plan.md の emoji ではなく、明示的な状態ファイルで管理する。

**実装案**: `{config_dir}/projects/{project}/phase-state.json`

```json
{
  "current_phase": 1,
  "phases": {
    "1": {
      "name": "API設計・実装",
      "status": "in_progress",
      "started_at": "2026-02-20T09:00:00Z",
      "tasks_created": ["#1", "#2", "#3", "#4"],
      "tasks_done": ["#1", "#2"]
    },
    "2": {
      "name": "フロントエンド実装",
      "status": "pending",
      "started_at": null,
      "tasks_created": [],
      "tasks_done": []
    }
  },
  "transitions": [
    {"from": null, "to": 1, "at": "2026-02-20T09:00:00Z", "by": "brain", "reason": "Auto: true"},
    {"from": 1, "to": 2, "at": "2026-02-22T15:00:00Z", "by": "brain", "reason": "Phase 1 criteria met"}
  ]
}
```

**brain.md への変更箇所** (Step 2.5 の Phase Advancement に追加):

```markdown
#### Phase State File

Phase 状態変更時には `phase-state.json` も更新する:
\```bash
python3 -c "
import json, datetime
path = '{config_dir}/projects/{project}/phase-state.json'
try:
    state = json.loads(open(path).read())
except:
    state = {'current_phase': 0, 'phases': {}, 'transitions': []}
state['current_phase'] = <new_phase_number>
state['phases']['<phase_number>'] = {'name': '<name>', 'status': '<status>', 'started_at': datetime.datetime.utcnow().isoformat()+'Z', 'tasks_created': [], 'tasks_done': []}
state['transitions'].append({'from': <old>, 'to': <new>, 'at': datetime.datetime.utcnow().isoformat()+'Z', 'by': '{agent_id}', 'reason': '<reason>'})
open(path, 'w').write(json.dumps(state, indent=2, ensure_ascii=False))
"
\```
```

**新規 mc コマンド案**:
```bash
mc -p <project> -m <mission> phase          # 現在の Phase と進捗を表示
mc -p <project> -m <mission> phase history   # Phase 遷移履歴を表示
```

### 提案 4: Plan Drift 検知（monitor の拡張）

**対象問題**: #3 解釈保証、#5 異常検知

monitor に「plan と実際のタスクの乖離（drift）」を検知する機能を追加する。

**monitor.md への変更箇所** (Step 5 に新セクション追加):

```markdown
#### e. Plan Drift Detection

If a plan exists (`mc -p {project} plan show` returns content):

1. Compare the plan's current phase tasks against actual board tasks:
   - **Unplanned tasks**: タスクが存在するが plan に対応エントリがないもの
   - **Missing tasks**: plan にあるが board に存在しないタスク（作成漏れ）
   - **Priority mismatch**: plan の priority と実際の priority が異なるもの
   - **Assignment mismatch**: plan の `@role` と実際の owner が異なるもの

2. 乖離を検出した場合:
   ```bash
   mc -p {project} -m {mission} msg {project}-{mission}-brain "[PLAN_DRIFT] <details>" --type alert
   ```

3. 重大な乖離（unplanned tasks > 2 or missing tasks > 0）の場合、escalator にも通知:
   ```bash
   mc -p {project} -m {mission} msg {project}-{mission}-escalator "[PLAN_DRIFT] Human review needed: <details>" --type alert
   ```
```

### 提案 5: 人間の介入チャネルの拡充

**対象問題**: #2 人間の介入ポイント

人間が能動的にミッションに介入するためのフローを明文化・強化する。

**5a. 即時 brain 起動コマンドの追加**:

```bash
# 人間が指示を送った直後に brain を即時起動（cron を待たない）
mc -p <project> -m <mission> mission instruct "認証方式をOAuth2に変更して" --run-brain
```

setup_mission.py に `--run-brain` フラグのヘルパーを追加し、内部で以下を実行:
```bash
mc -p <project> -m <mission> mission instruct "<text>"
openclaw --profile <profile> agents run <project>-<mission>-brain
```

**5b. ダッシュボードコマンドの追加**:

```bash
mc -p <project> -m <mission> dashboard
```

出力例:
```
=== Mission Dashboard: proj/v1 ===
Status: ACTIVE    Phase: 2/3 (フロントエンド実装)
Uptime: 3d 4h     Last brain run: 2h ago

Phase Progress:
  [1] API設計・実装      ████████████ 100%  ✅
  [2] フロントエンド実装  ████████░░░░  67%  🔄
  [3] 統合テスト         ░░░░░░░░░░░░   0%  ⏳

Active Tasks:
  #12 テンプレート実装    frontend   in_progress  P0  2h
  #13 API連携           frontend   pending       P1

Agent Status:
  backend    idle       last_seen: 1h ago   cron: disabled
  frontend   working    last_seen: 5m ago   cron: enabled
  reviewer   idle       last_seen: 6h ago   cron: disabled

Recent Decisions (last 24h):
  [15:00] brain: task_create #13 "API連携" for frontend
  [09:00] brain: phase_advance Phase 1 → Phase 2
  [08:55] monitor: observation - all Phase 1 tasks done

Alerts: none
```

**5c. brain テンプレートに指示解釈確認を追加**:

brain.md の Step 5b「User Instructions」を以下に変更:

```markdown
#### b. User Instructions
If `mission status` shows user instructions:
1. Interpret the instructions and translate into concrete task adjustments
2. **Before executing changes**, log the interpretation:
   ```bash
   echo '{"ts":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'","agent":"{agent_id}","type":"user_instruction","instruction":"<original>","interpretation":"<your plan>","actions":["<action1>","<action2>"]}' >> "{config_dir}/projects/{project}/decision-log.jsonl"
   ```
3. Execute the planned actions (create/modify/reassign tasks)
4. Report to escalator for human confirmation:
   ```bash
   mc -p {project} -m {mission} msg {project}-{mission}-escalator "Executed user instruction: <summary of changes made>. Please confirm with human." --type status
   ```
```

### 提案 6: brain 初回実行時のタスク作成検証

**対象問題**: #3 解釈保証、#6 引き継ぎギャップ

brain が Phase 1（Auto: true）のタスクを初回作成した後、自己検証ステップを追加する。

**brain.md への変更箇所** (Step 2.5 C-2「CREATE」の末尾に追加):

```markdown
#### Task Creation Verification

After creating all tasks for a phase, verify the creation:
1. Run `mc -p {project} -m {mission} list --all` to get actual created tasks
2. Compare against plan:
   - Count match: plan のタスク数 == 作成されたタスク数
   - Assignment match: 各タスクの owner が plan の `@role` と一致
   - Priority match: 各タスクの priority が plan の指定と一致
3. If discrepancies found:
   - Log the discrepancy to decision-log.jsonl
   - Auto-correct if possible (e.g., missing task → create it)
   - If auto-correction fails, escalate:
     ```bash
     mc -p {project} -m {mission} add "Human: Task creation verification failed — <details>" --for {project}-{mission}-escalator
     ```
```

---

## トレードオフ

### 提案 1 (Decision Log)
- **オーバーヘッド**: 各セッションで追加の bash コマンド実行（1-2回）。jsonl ファイルの肥大化。
- **リスク**: LLM が正しい JSON を生成しない可能性。echo でのJSON生成はエスケープ問題を起こしやすい。
- **緩和策**: python3 ワンライナーでJSON生成を行う。定期的なログローテーション。

### 提案 2 (YAML フロントマター)
- **オーバーヘッド**: architect が plan.md を作成する際の作業量増加。YAML の構文を正しく書く必要がある。
- **リスク**: フロントマターと Markdown 本文の二重管理。不整合が発生する可能性。
- **緩和策**: setup_mission.py でバリデーションを行う。フロントマターを信頼のソースとし、Markdown 本文は人間向けのドキュメントとして位置づける。
- **互換性**: フロントマターがない既存の plan.md もフォールバックで動作するため、後方互換性あり。

### 提案 3 (Phase 状態マシン)
- **オーバーヘッド**: brain の各セッションで JSON ファイル読み書きが追加される。
- **リスク**: phase-state.json と plan.md の二重管理。brain が片方だけ更新して不整合になる可能性。
- **緩和策**: monitor の drift 検知（提案4）で不整合を検出する。

### 提案 4 (Plan Drift 検知)
- **オーバーヘッド**: monitor のセッション時間が増加（plan パース + 比較処理）。
- **リスク**: 自然言語のタスク説明のマッチング精度が低い場合、false positive が多発する。
- **緩和策**: フロントマター（提案2）が導入されていれば、構造化データの比較で精度が向上する。

### 提案 5 (介入チャネル拡充)
- **オーバーヘッド**: dashboard コマンドの実装コスト。brain の即時起動は cron 外のセッション消費。
- **リスク**: `--run-brain` の乱用で brain のセッションコストが増加。
- **緩和策**: `--run-brain` は人間が明示的に実行する場合のみ。レート制限の検討。

### 提案 6 (タスク作成検証)
- **オーバーヘッド**: brain のセッション時間が若干増加（追加の list コマンド実行 + 比較ロジック）。
- **リスク**: 検証ロジック自体が LLM の解釈に依存する点は変わらない。
- **緩和策**: フロントマター（提案2）と組み合わせることで、構造化データに基づく厳密な検証が可能になる。

### 全体的トレードオフ
- **複雑性の増加**: 提案全体で、エージェントテンプレートに追加されるステップ数が増え、LLM が正しくワークフローを実行する難易度が上がる。
- **ファイル数の増加**: decision-log.jsonl, phase-state.json の追加でファイル管理が複雑になる。
- **セッションコスト**: 各セッションで追加の bash コマンド実行が発生し、トークン消費が増加する。

---

## 優先度マトリクス

| 優先度 | 提案 | 理由 |
|--------|------|------|
| **High** | 提案 2: YAML フロントマター | plan.md の解釈エラーは最も致命的。構造化により brain のタスク作成精度が根本的に向上する。実装も比較的容易（plan.md のフォーマット変更 + brain テンプレートの指示追加）。提案4, 6 の前提条件でもある。 |
| **High** | 提案 6: タスク作成検証 | 「作ったタスクが正しいか確認する」は最小限のコストで最大の安全性を得られる。フロントマターなしでも部分的に機能する。 |
| **High** | 提案 5c: brain の指示解釈確認 | 人間の指示が正しく解釈されたことの確認は、ミッションの方向性を守る上で不可欠。 |
| **Medium** | 提案 1: Decision Log | デバッグと事後分析に極めて有用だが、ミッションの成功自体には直接寄与しない。ファイルへの書き込み処理が LLM に正しく実行されるかの懸念もある。 |
| **Medium** | 提案 4: Plan Drift 検知 | monitor の拡張として自然だが、フロントマター（提案2）がないと精度が低い。提案2の導入後に実装するのが効果的。 |
| **Medium** | 提案 5a: 即時 brain 起動 | 緊急介入に有用だが、`openclaw agents run` コマンドで代替可能（仕様書 Step 5 に既に記載）。UX の改善レベル。 |
| **Low** | 提案 3: Phase 状態マシン | 理想的だが、phase-state.json と plan.md の二重管理リスクが高い。YAML フロントマター内で Phase 状態を管理する方がシンプルかもしれない。`mc phase` コマンドの実装コストも考慮が必要。 |
| **Low** | 提案 5b: Dashboard コマンド | 可視化として価値が高いが、既存の `mc board` + `mc fleet` + `mc plan show` で代替可能。実装コストに対する追加価値が限定的。 |

### 推奨実装順序

```
Phase 1 (即時): 提案 2 (YAML フロントマター) + 提案 6 (タスク作成検証)
  → plan.md の信頼性を構造的に保証する基盤を先に構築

Phase 2 (短期): 提案 1 (Decision Log) + 提案 5c (指示解釈確認)
  → 判断の追跡可能性と人間との対話品質を向上

Phase 3 (中期): 提案 4 (Plan Drift 検知) + 提案 5a (即時 brain 起動)
  → 運用時の異常検知と介入性を強化

Phase 4 (長期): 提案 3 (Phase 状態マシン) + 提案 5b (Dashboard)
  → 完全な可観測性プラットフォームへの発展
```
