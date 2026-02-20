# Agent A: 耐障害性仮説

## 仮説

現在の OMOS は LLM エージェントの不確実性（指示無視、クラッシュ、部分実行、状態の不整合）に対して脆弱であり、各ステップにガードレール・冪等性・状態検証を組み込まなければ、本番運用で「サイレント障害」（誰も気づかないままミッションが停止する状態）が常態化する。

---

## 現状の問題点

### 1. Cron Guard のベストエフォート方式は「黙って壊れる」

**該当箇所**: 仕様書 Section 7「Cron Guard パターン」、全テンプレートの Step 0

**問題**: Cron Guard が失敗した場合「スキップしてワークフロー続行」と明記されている（brain.md:25, base.md:27, monitor.md:25）。これは以下の障害シナリオを生む:

- **シナリオ A**: Cron Guard の disable が失敗 → ワークフロー実行中に次の cron トリガーが発火 → 同一タスクを2つのセッションが同時に claim/start → タスク状態の競合、ファイルの同時書き込み
- **シナリオ B**: ワークフロー完了後の re-enable が失敗 → cron が無効のまま → エージェント永久停止。monitor の Stale Agent Recovery が唯一の救済だが、monitor 自身も同じ問題を抱えている

**致命的な点**: monitor が Cron Guard 失敗でスタックした場合、他のエージェントの Stale Agent Recovery を実行する主体がいなくなる。**monitor の monitor が存在しない**。

### 2. タスクの claim/start/done に原子性がない

**該当箇所**: base.md Step 4-6、brain.md Step 2.5 C

**問題**: タスクの状態遷移が複数の独立したコマンドで構成されている:

```bash
mc claim <id>     # (1) pending → claimed
mc start <id>     # (2) claimed → in_progress
# ... 作業 ...
mc done <id>      # (3) in_progress → done
```

各コマンド間でクラッシュが発生すると:
- **(1)と(2)の間でクラッシュ**: claimed のまま放置。再起動時に再度 claim しようとしてエラー、または別タスクを取りに行く
- **(2)と(3)の間でクラッシュ**: in_progress のまま放置。作業は半完了状態。再起動時に「最も優先度の高い pending タスク」を探すため、この半完了タスクは放棄される
- **brain の Phase Advancement（Step 2.5 C-1）**: checkpoint の add → claim → start → done が4ステップある。途中クラッシュで checkpoint が中途半端な状態になり、Phase 管理が破綻する

### 3. brain の plan.md 書き込みが非原子的で競合する

**該当箇所**: brain.md Step 2.5 A「Annotate Progress」

**問題**: brain は `cat > "$(mc -p {project} plan path)" << 'PLAN_EOF'` で plan.md を上書きする。これには複数のリスクがある:

- **書き込み中のクラッシュ**: heredoc の途中でセッションが killed されると、plan.md が空または不完全な状態で残る。次回起動時に brain が壊れた plan を読み込み、Phase 管理が完全に破綻する
- **LLM の幻覚による改変**: brain は LLM であり、plan.md の「Do NOT change: Goal, phase order, human-written task descriptions」という指示を無視して内容を勝手に改変するリスクがある。変更の検証メカニズムがない
- **バージョン管理がない**: plan.md の変更履歴が追跡されないため、いつ誰が何を変えたか不明

### 4. LLM の指示無視（Instruction Drift）への対策がない

**該当箇所**: 全テンプレート、仕様書 Section 12「禁止事項」

**問題**: 仕様書には「mc-architect は mc add を絶対に使わない」「コードを自分で書くな」等の禁止事項があるが、これらは自然言語の指示に過ぎず、**強制力がない**。LLM エージェントは以下の理由で指示を逸脱する:

- **コンテキスト長の問題**: AGENTS.md が長くなるにつれ、後半の Safety Rules の遵守率が低下する
- **cron メッセージとの矛盾**: cron メッセージ（setup_mission.py:166-173）は簡潔な指示だが、AGENTS.md の詳細なワークフローと齟齬がある場合、LLM はどちらを優先するか予測不能
- **brain の過剰行動**: brain は「Judge and Act」で広範な裁量権を持ち、タスクの作成・再割当・Phase 管理を行う。この裁量が暴走して、plan.md にないタスクを大量生成したり、Phase をスキップするリスクがある

### 5. setup_mission の部分実行からの復旧が不可能

**該当箇所**: setup_mission.py、仕様書 Section 12「失敗時の対応」

**問題**: `setup_mission` は6ステップ（project init → mission create → directory → plan copy → worker agents → supervisor agents）を順次実行するが、**途中失敗時のロールバック機構がない**:

- Step 4（worker agents）の途中で3人中2人が登録されて失敗した場合、再実行すると既存エージェントとの重複エラー
- `register_agent` 内の5サブステップ（workspace → AGENTS.md → openclaw agent → MC fleet → cron）も同様。cron 追加だけ失敗したエージェントは「登録済みだが起動しない幽霊エージェント」になる
- 仕様書は「リトライ → 再失敗なら Slack で報告」としか言っていないが、冪等でないためリトライが安全でない

### 6. monitor の Stale Agent Recovery の検知条件が不十分

**該当箇所**: 仕様書 Section 7「Monitor の Stale Agent Cron Recovery」、monitor.md Step 5d

**問題**: 検知条件は「`last_seen` > 20分前 AND pending/in_progress タスクあり」だが:

- **last_seen の更新タイミング**: `mc checkin` でのみ更新される。エージェントが Step 0（Cron Guard）でクラッシュした場合、checkin に到達しないため last_seen が更新されず、前回の last_seen のまま。これは「20分以上前」の条件を満たすが、**checkin 前のクラッシュとcheckin 後の長時間タスクの区別がつかない**
- **monitor 自身の障害**: monitor がクラッシュして cron 無効のまま停止した場合、誰が monitor を復旧するのか。現状の設計には **self-healing 機構がない**
- **6時間間隔の遅延**: supervisor のデフォルト cron は6時間ごと。worker が1時間前にクラッシュしても、最大6時間は放置される

### 7. エスカレーションの到達保証がない

**該当箇所**: escalator.md、仕様書 Section 6

**問題**: エスカレーションのフローは `brain → escalator タスク作成 → escalator が Slack に投稿` だが:

- escalator の cron が無効のまま停止している場合、brain がタスクを作成しても escalator は起動しない（brain が cron を再有効化するが、これもベストエフォート）
- Slack 通知は cron の `--announce` 機能に依存しており、escalator セッション自体が正常完了する必要がある
- **クリティカルなエスカレーション（セキュリティインシデント等）が最大6時間遅延しうる**

### 8. in_progress タスクの再開メカニズムがない

**該当箇所**: base.md Step 7「Next Task or Stop」

**問題**: Worker は再起動時に `mc list --mine --status pending` で次のタスクを探す。しかし:

- 前回のセッションで `start` したが `done` にできなかった in_progress タスクは **pending ではない** ため、このクエリに引っかからない
- 仕様書にもテンプレートにも「in_progress の自分のタスクを再開する」ロジックが存在しない
- 結果として、in_progress タスクは永久に放棄される（monitor が STALE として検知するまで）

---

## 改善提案

### 提案 1: in_progress タスクの優先再開ロジック（問題点 2, 8 を解決）

**base.md の Step 3「Find Work」を修正**:

```markdown
### 3. Resume or Find Work

First, check for your own in-progress tasks (from a previous crashed session):
```bash
mc -p {project} -m {mission} list --mine --status in_progress
```

If you have an in_progress task:
- **Resume it** — read the task description, check what was already done (inspect files in the working directory), continue from where it left off.
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

**理由**: クラッシュリカバリの最も基本的なパターン。in_progress タスクは「前回のセッションが途中で死んだ」ことを示す最も信頼性の高いシグナル。

### 提案 2: plan.md の安全な書き込みと変更検証（問題点 3 を解決）

**brain.md の Step 2.5 A を修正**:

```markdown
#### A. Annotate Progress (Safe Write Pattern)

**Step A-1: Backup before modification**
```bash
cp "$(mc -p {project} plan path)" "$(mc -p {project} plan path).bak.$(date +%Y%m%d%H%M%S)"
```

**Step A-2: Write to temporary file first**
```bash
cat > "$(mc -p {project} plan path).tmp" << 'PLAN_EOF'
<full updated plan content here>
PLAN_EOF
```

**Step A-3: Validate the temporary file**
```bash
# Check that the tmp file is non-empty and contains the Goal section
[ -s "$(mc -p {project} plan path).tmp" ] && grep -q "^## Goal" "$(mc -p {project} plan path).tmp" && mv "$(mc -p {project} plan path).tmp" "$(mc -p {project} plan path)" && echo "[PLAN] Updated successfully" || echo "[PLAN] ERROR: validation failed, keeping original"
```

**Immutable sections**: The following MUST remain identical to the original plan:
- `## Goal` line content
- Phase names and their order
- Task descriptions written by the human (only add suffixes like ` → #<task-id>`)

**Verification**: After writing, diff the backup with the new file. If Goal or phase names changed, revert:
```bash
diff <(grep "^## " "$(mc -p {project} plan path).bak."*) <(grep "^## " "$(mc -p {project} plan path)") || echo "[PLAN] WARNING: Structure changed — review needed"
```
```

### 提案 3: setup_mission の冪等性確保（問題点 5 を解決）

**setup_mission.py の `register_agent` 関数を修正**:

```python
def register_agent(
    agent_id: str,
    role: str,
    project: str,
    ws_dir: Path,
    agents_md: str,
    cron_schedule: str,
    cron_msg: str,
    slack_channel: str,
    oc_profile_flag: str,
    profile_env: str,
    dry_run: bool,
    model: str | None = None,
) -> None:
    """Register a single agent with idempotency checks."""

    # a. Create workspace (already idempotent via exist_ok=True)
    if not dry_run:
        ws_dir.mkdir(parents=True, exist_ok=True)

    # b. Write AGENTS.md (always overwrite — idempotent)
    agents_md_path = ws_dir / "AGENTS.md"
    if not dry_run:
        agents_md_path.write_text(agents_md)

    # c. Register openclaw agent (check if exists first)
    result = run(
        f"openclaw {oc_profile_flag} agents list --json",
        capture=True, check=False,
    )
    agent_exists = agent_id in (result.stdout or "")

    if not agent_exists and not dry_run:
        run(
            f"openclaw {oc_profile_flag} agents add {agent_id} "
            f"--workspace {ws_dir} "
            f"{f'--model {model} ' if model else ''}"
            f"--non-interactive",
            check=False,
        )

    # d. Register in MC fleet (mc register is already idempotent)
    if not dry_run:
        run(
            f"{profile_env}MC_AGENT={agent_id} mc -p {project} register {agent_id} --role {role}",
            check=False,
        )

    # e. Add cron job (check if exists first)
    cron_result = run(
        f"openclaw {oc_profile_flag} cron list --json",
        capture=True, check=False,
    )
    cron_exists = agent_id in (cron_result.stdout or "")

    if not cron_exists and not dry_run:
        escaped_msg = cron_msg.replace('"', '\\"')
        run(
            f'openclaw {oc_profile_flag} cron add '
            f'--agent {agent_id} --name {agent_id} '
            f'--cron "{cron_schedule}" --session isolated '
            f'--announce --channel slack --to {slack_channel} '
            f'--message "{escaped_msg}"',
            check=False,
        )

    print(f"  OK — {agent_id} {'(already existed)' if agent_exists else 'ready'}")
```

**追加: 最終検証ステップ**を `main()` の末尾に追加:

```python
# ─── Step 6.5: Verify all agents are registered ───
print(f"\n[6.5/7] Verifying agent registration...")
verification_failed = False
for agent_id in agents_created:
    # Check openclaw agent exists
    result = run(
        f"openclaw {oc_profile_flag} agents list --json",
        capture=True, check=False,
    )
    if agent_id not in (result.stdout or ""):
        print(f"  FAIL: {agent_id} not found in openclaw agents")
        verification_failed = True

    # Check cron exists
    cron_result = run(
        f"openclaw {oc_profile_flag} cron list --json",
        capture=True, check=False,
    )
    if agent_id not in (cron_result.stdout or ""):
        print(f"  FAIL: {agent_id} cron not found")
        verification_failed = True

if verification_failed:
    print("\nWARNING: Some agents failed verification. Run setup_mission again (it is idempotent).")
    sys.exit(1)
```

### 提案 4: Monitor の自己回復と多重監視（問題点 1, 6 を解決）

**monitor.md に「Step 0.5: Self-Health Check」を追加**:

```markdown
### 0.5. Self-Health Check

Verify that the brain agent's cron is active (mutual monitoring):
```bash
brain_cron_status=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "
import sys,json
jobs = json.load(sys.stdin).get('jobs',[])
for j in jobs:
    if j.get('name') == '{project}-{mission}-brain':
        print(j.get('status', 'unknown'))
        break
else:
    print('not_found')
")
echo "[MONITOR] brain cron status: $brain_cron_status"
```

If brain's cron is disabled and brain's `last_seen` > 20 minutes:
```bash
cron_id_brain=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{project}-{mission}-brain']") && openclaw --profile "$OPENCLAW_PROFILE" cron enable "$cron_id_brain" && echo "[MONITOR] brain cron re-enabled (stale recovery)"
```
```

**brain.md にも monitor の相互監視ロジックを追加**:

```markdown
### 3.5. Monitor Health Check

Verify monitor's cron is active:
```bash
monitor_cron_active=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "
import sys,json
for j in json.load(sys.stdin).get('jobs',[]):
    if j.get('name') == '{project}-{mission}-monitor':
        print('enabled' if j.get('enabled', False) else 'disabled')
        break
else:
    print('not_found')
")
```

If monitor's cron is disabled, re-enable it:
```bash
cron_id_monitor=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{project}-{mission}-monitor']") && openclaw --profile "$OPENCLAW_PROFILE" cron enable "$cron_id_monitor" && echo "[BRAIN] monitor cron re-enabled"
```
```

**効果**: brain と monitor が相互に cron 状態を監視し合うことで、片方が死んでももう片方が復旧できる。両方が同時に死ぬ確率は単体の二乗に低下する。

### 提案 5: LLM の指示逸脱を検知するガードレール（問題点 4 を解決）

**mc CLI にコマンド監査ログ機能を追加する設計**:

```markdown
### 提案: mc audit-log

全エージェントの mc コマンド実行を監査ログに記録:

```
{config_dir}/projects/{project}/audit.jsonl
```

各行の形式:
```json
{"ts": "2026-02-20T10:00:00Z", "agent": "proj-m1-brain", "cmd": "add", "args": {"subject": "...", "for": "proj-m1-coder"}, "result": "ok"}
```

brain テンプレートに以下の検証ステップを追加:

### 5.5. Action Audit

Before creating tasks, verify:
1. Total tasks created in this session < 10 (prevent runaway task creation)
2. All task assignments target agents that exist in `mc fleet`
3. No tasks created for roles not in the plan

If any violation: stop and escalate to human.
```

**テンプレートレベルでの制限（brain.md に追加）**:

```markdown
## Guardrails

- **Task creation limit**: Create at most **7 tasks per session**. If more are needed, note it and defer to next cycle.
- **Phase discipline**: Only create tasks that appear in the current or next phase of plan.md. Never skip phases.
- **No self-assignment**: Do not assign tasks to yourself (brain). Brain observes and directs; it does not execute.
- **Escalation threshold**: If you are uncertain about any decision (confidence < 70%), escalate to human via escalator instead of acting.
```

### 提案 6: エスカレーションの到達保証（問題点 7 を解決）

**escalator.md のワークフローに「直接 Slack 通知」オプションを追加**:

現状では escalator は cron の `--announce` 機能で Slack に通知するが、これはセッション全体の完了に依存する。代わに、クリティカルなエスカレーションはワークフロー内で直接 Slack API を呼ぶべき。

ただし、現在の OMOS は Slack API を直接叩く機構を持っていない。代替案:

```markdown
### 3. Process Escalation Tasks (Enhanced)

For each escalation task:
1. Classify severity:
   - **CRITICAL** (security, data loss, budget): Must reach human within 1 hour
   - **HIGH** (blocker, unclear requirements): Should reach human within 6 hours
   - **NORMAL** (design decisions, approvals): Next cycle is acceptable

2. For CRITICAL escalations:
   - Process the task (claim → start → done) to ensure cron --announce fires
   - Additionally, create a backup notification task for brain:
     ```bash
     mc -p {project} -m {mission} msg {project}-{mission}-brain "[CRITICAL_ESCALATION] <summary> — human notification sent via Slack" --type alert
     ```
   - If this session completes normally, Slack --announce will deliver the message

3. For all severities: include in session output:
   ```
   [ESCALATION] Severity: CRITICAL/HIGH/NORMAL
   To: <@{slack_user_id}>
   From: <requesting-agent>
   Subject: <what is needed>
   Context: <why it's needed>
   Options: <what choices the human has>
   Deadline: <when a response is needed by>
   ```
```

**追加安全策**: brain が escalator の応答を検証する:

```markdown
### brain.md に追加: Step 5f. Escalation Delivery Verification

Check if escalation tasks assigned to escalator are stuck:
```bash
mc -p {project} -m {mission} list --owner {project}-{mission}-escalator --status pending
```

If escalation tasks have been pending > 12 hours:
- Re-enable escalator's cron
- If still unprocessed after another cycle: create a WARNING message in session output for Slack --announce
```

### 提案 7: Cron Guard の堅牢化（問題点 1 を部分的に解決）

完全な排他制御は現在のアーキテクチャでは難しいが、**楽観的ロック** を導入できる:

**全テンプレートの Step 0 を強化**:

```markdown
### 0. Cron Guard with Session Lock

```bash
LOCK_FILE="{config_dir}/projects/{project}/.lock.{agent_id}"

# Check if another session is already running
if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0) ))
  if [ "$LOCK_AGE" -lt 1800 ]; then
    echo "[CRON_GUARD] {agent_id}: another session is running (lock age: ${LOCK_AGE}s), aborting"
    # Re-enable cron so we try again next cycle
    cron_id=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw --profile "$OPENCLAW_PROFILE" cron enable "$cron_id"
    exit 0
  else
    echo "[CRON_GUARD] {agent_id}: stale lock detected (age: ${LOCK_AGE}s), overriding"
  fi
fi

# Create lock file
echo "$$" > "$LOCK_FILE"

# Disable cron (best-effort)
cron_id=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw --profile "$OPENCLAW_PROFILE" cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled at $(date '+%Y-%m-%d %H:%M:%S') — session started"
```

**セッション終了時（全テンプレートの最終ステップに追加）**:

```bash
# Remove lock file
rm -f "{config_dir}/projects/{project}/.lock.{agent_id}"
```
```

**注意**: これはファイルベースの楽観的ロックであり、NFS 等の分散ファイルシステムでは安全でない。しかし、OMOS は単一マシンで動作する前提なので十分。

### 提案 8: セッション状態のチェックポイント記録（問題点 2 を部分的に解決）

**Worker テンプレートに「セッション状態ファイル」を追加**:

```markdown
### 4.5 Record Session State

After claiming and starting a task, record the current state:
```bash
cat > "{config_dir}/projects/{project}/.session.{agent_id}.json" << SESSION_EOF
{"task_id": "<id>", "status": "in_progress", "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "session_pid": "$$"}
SESSION_EOF
```

### 6.5 Clear Session State

After completing the task:
```bash
rm -f "{config_dir}/projects/{project}/.session.{agent_id}.json"
```
```

**Step 3 の「Resume or Find Work」でこのファイルを参照**:

```markdown
### 3. Resume or Find Work

Check for a previous session state file:
```bash
if [ -f "{config_dir}/projects/{project}/.session.{agent_id}.json" ]; then
  echo "[RECOVERY] Found previous session state — resuming"
  cat "{config_dir}/projects/{project}/.session.{agent_id}.json"
fi
```

If a session state file exists, resume that task (check its current status via `mc list`).
If the task is still `in_progress`, continue working on it.
If the task was already completed or reassigned, remove the stale session file.
```

---

## トレードオフ

| 提案 | メリット | デメリット |
|------|---------|-----------|
| 1. in_progress 再開 | クラッシュ後の作業継続、タスク放棄防止 | LLM が「途中から再開」を正確に行えるか不確実。部分的に完了した作業の状態把握が困難 |
| 2. plan.md 安全書き込み | データ損失防止、変更追跡可能 | テンプレートの複雑化、バックアップファイルの蓄積、LLM が複数ステップのファイル操作を正確に実行するか不確実 |
| 3. setup_mission 冪等化 | 安全なリトライ、部分障害からの復旧 | 実装コスト増加、存在確認の API コール追加による実行時間増 |
| 4. 相互監視 | 単一障害点の解消 | テンプレートの複雑化、supervisor 同士の cron 操作が増え API コスト増。相互監視がカスケード障害を引き起こすリスク |
| 5. LLM ガードレール | 暴走防止、予測可能な動作 | タスク作成上限が正当なケースを阻害する可能性。監査ログは mc CLI の改修が必要 |
| 6. エスカレーション到達保証 | クリティカル通知の確実な配信 | Slack 直接通知には追加インフラが必要。現状では cron --announce への依存を完全には排除できない |
| 7. ファイルロック | 二重実行の確実な防止 | ファイルシステム依存、ロックファイルの残骸によるデッドロックリスク（30分タイムアウトで軽減） |
| 8. セッション状態記録 | きめ細かなクラッシュリカバリ | セッション状態ファイルの管理負荷、LLM がファイル操作を正確に行うかの不確実性 |

**全体的なトレードオフ**: これらの提案はすべてテンプレートの複雑化を伴う。LLM エージェントは複雑な指示ほど遵守率が下がるため、**「ガードレールを増やすことで逆に障害率が上がる」** というパラドックスが存在する。最小限の変更で最大の効果を得るものから段階的に導入すべき。

---

## 優先度マトリクス

### High（即座に対応すべき）

| # | 提案 | 理由 |
|---|------|------|
| 1 | in_progress タスクの優先再開 | **変更が最小限**（base.md の Step 3 に3行追加）で **最大の効果**（タスク放棄を防止）。LLM が理解しやすい単純なロジック |
| 4 | brain-monitor 相互監視 | **単一障害点の解消** は運用上最も重要。monitor が死ぬとシステム全体の回復機構が失われる。各テンプレートに5行程度の追加で実装可能 |
| 3 | setup_mission の冪等化 | **mc-architect が最初に実行するコマンド** であり、ここが壊れるとミッション全体が起動しない。Python コードの修正なので LLM の不確実性に影響されない |

### Medium（次のイテレーションで対応）

| # | 提案 | 理由 |
|---|------|------|
| 2 | plan.md 安全書き込み | plan.md の破損は深刻だが、発生確率は比較的低い（brain のセッションが heredoc 途中で kill される確率）。バックアップの1行だけでも先に入れる価値あり |
| 5 | LLM ガードレール（テンプレート部分） | brain.md に Guardrails セクションを追加するだけなら低コスト。監査ログは mc CLI の改修が必要なため後回し |
| 7 | ファイルロック（Cron Guard 強化） | 二重実行の実害は「同一タスクの競合 claim」だが、mc CLI 側で claim の排他制御があれば影響は限定的 |

### Low（長期的に検討）

| # | 提案 | 理由 |
|---|------|------|
| 6 | エスカレーション到達保証 | 現状の cron --announce が機能する限り、追加のインフラ投資は見合わない。escalator の cron が6時間以内に正常実行される確率は十分高い |
| 8 | セッション状態記録 | 提案1（in_progress 再開）が実装されれば、mc CLI のタスク状態だけでほとんどのケースをカバーできる。ファイルベースの状態記録は追加の複雑性に見合うほどの効果がない可能性が高い |

---

## 補足: 設計哲学への提言

現在の OMOS は **「LLM は指示を正確に実行する」** という楽観的な前提に立っている。しかし、本番運用では LLM は以下の理由で指示から逸脱する:

1. **確率的実行**: 同じ入力でも毎回異なる出力を生成する
2. **コンテキスト長限界**: テンプレートが長くなるほど後半の指示の遵守率が低下する
3. **意味理解の限界**: 「mc add を使うな」と書いても、LLM が「この状況ではmc add が最善」と判断すれば使ってしまう

対策の基本原則:

- **LLM の出力を信頼せず、検証する**: mc CLI 側で不正な操作を拒否する（例: brain 以外のエージェントによる `mc add` をブロック）
- **テンプレートは短く、明確に**: 長いテンプレートより短いテンプレートのほうが遵守率が高い
- **状態は外部（mc CLI / ファイルシステム）に持つ**: LLM のメモリに頼らず、毎回外部状態を読み直す
- **最悪のケースでも人間に通知が届く設計にする**: 全自動復旧を目指すより、「壊れたら人間に教える」を確実にする
