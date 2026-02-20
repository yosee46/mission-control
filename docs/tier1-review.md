# Tier 1 コードレビュー結果

## 総合判定: APPROVE (条件付き)

全体として Tier 1 仕様に対する実装は正確で、主要な要件を全て満たしている。
以下に問題点として挙げる項目は全て軽微（cosmetic / dead text）であり、機能に影響しない。
修正推奨だが、APPROVE をブロックするものではない。

---

## レビュー項目別結果

### 1. 仕様準拠性

- [PASS] `mc cron-guard` が disable/enable/check の3操作をサポート: `mc:972-1023` に `cmd_cron_guard()` が実装されており、disable/enable/check の3サブコマンドを正しくサポートしている。
- [PASS] ベストエフォート（cron job 未発見時にエラー終了しない）: `mc:991-993` で cron_id が空の場合 `return 0` しており、`set -euo pipefail` と矛盾しない（`return 0` は正常終了）。
- [PASS] `OPENCLAW_PROFILE` 自動参照: `mc:977-978` で `OPENCLAW_PROFILE` 環境変数を参照し、`--profile` フラグを構築している。
- [PASS] dispatch テーブルへの登録: `mc:1167` に `cron-guard) shift; cmd_cron_guard "$@" ;;` が登録されている。
- [PASS] DB不要コマンドリストへの登録: `mc:1135` の `case` 文に `cron-guard` が含まれている。
- [PASS] help テキストへの登録: `mc:1103-1107` に CRON GUARD セクションが追加されている。

### 2. テンプレート Cron Guard 置換

- [PASS] base.md: 旧3行ワンライナーが完全に除去され、Step 0 (`mc:24`) に `mc cron-guard disable {agent_id}`、Step 8 (`mc:96`) に `mc cron-guard enable {agent_id}` が記述されている。
- [PASS] brain.md: Step 0 (`brain.md:22`) に disable、Step 7 (`brain.md:204`) に enable、Step 6 (`brain.md:185`) にターゲットエージェント用の `mc cron-guard enable <agent-id>` が記述されている。
- [PASS] monitor.md: Step 0 (`monitor.md:22`) に disable、Step 6 (`monitor.md:87`) に enable、Step 5d (`monitor.md:79`) に stale agent recovery 用の `mc cron-guard enable <agent-id>` が記述されている。
- [PASS] escalator.md: Step 0 (`escalator.md:41`) に disable、Step 1 (`escalator.md:54`) と Step 5 (`escalator.md:88`) に enable が記述されている。
- [WARN] 全4テンプレートに `$cron_id` への言及テキストが残存（後述の「推奨改善」参照）。

### 3. base.md in_progress 再開ロジック

- [PASS] Step 3 が "Resume or Find Work" に変更されている: `base.md:47` に `### 3. Resume or Find Work` と記述。
- [PASS] in_progress 確認が pending 確認より先: `base.md:50-52` で `--status in_progress` を先に確認し、`base.md:59` で `--status pending` を後に確認している。
- [PASS] 再開手順が明記されている: `base.md:54-56` に「Resume it — check what was already done, continue from where it left off」と記述。
- [PASS] 旧 Step 3 "Find Work" タイトルが残っていない: 確認済み、"Resume or Find Work" に変更されている。
- [PASS] unclaimed work の確認も含まれている: `base.md:63-66` に `mc list --status pending`（owner フィルタなし）が記述。仕様書の `mc list --status pending`（unclaimed work 確認）に対応。

### 4. cron メッセージ最小化

- [PASS] `generate_cron_message()` がシンプルなメッセージ: `setup_mission.py:197-202` で「You are {agent_id}. Read your AGENTS.md and execute your workflow. 日本語で応答すること。」のみ。
- [PASS] supervisor 用関数も統一メッセージ: `generate_monitor_cron_message()` (`setup_mission.py:309-311`), `generate_brain_cron_message()` (`setup_mission.py:314-316`), `generate_escalator_cron_message()` (`setup_mission.py:319-321`) が全て `generate_cron_message(agent_id)` を呼び出している。
- [PASS] 旧メッセージ（mc コマンド手順等）が除去されている: 旧メッセージのパターン（checkin, list --mine 等の手順記載）は存在しない。

### 5. setup_mission.py 冪等化

- [PASS] `agent_exists()` ヘルパー関数が追加されている: `setup_mission.py:62-78`。`--json` フラグで agents list を取得し、name/id を照合。`check=False` でエラーハンドリング済み。
- [PASS] `cron_exists()` ヘルパー関数が追加されている: `setup_mission.py:81-94`。`--json` フラグで cron list を取得し、name を照合。`json.JSONDecodeError` と `AttributeError` をキャッチ。
- [PASS] `register_agent()` 内で agent 登録前に `agent_exists()` チェック: `setup_mission.py:351-352`。存在する場合はスキップ。
- [PASS] `register_agent()` 内で cron 登録前に `cron_exists()` チェック: `setup_mission.py:374-375`。存在する場合はスキップ。
- [PASS] `main()` 末尾に最終検証ステップ: `setup_mission.py:720-735`。全 agent の agent_exists + cron_exists を検証し、WARN メッセージを出力。
- [PASS] エラーハンドリング（`check=False`, try/except）が適切: 各ヘルパー関数で `check=False` を使用し、JSON パースエラーを安全にキャッチしている。

### 6. フォールバックテンプレート

- [PASS] base フォールバック（`setup_mission.py:126-148`）: `mc cron-guard disable {agent_id}` と `mc cron-guard enable {agent_id}` を使用。
- [PASS] monitor フォールバック（`setup_mission.py:212-235`）: `mc cron-guard disable {agent_id}`, `mc cron-guard enable {agent_id}`, `mc cron-guard enable <agent-id>`（stale recovery）を使用。
- [PASS] brain フォールバック（`setup_mission.py:245-268`）: `mc cron-guard disable {agent_id}`, `mc cron-guard enable {agent_id}`, `mc cron-guard enable <agent>`（タスクアサイン時）を使用。
- [PASS] escalator フォールバック（`setup_mission.py:279-306`）: `mc cron-guard disable {agent_id}`, `mc cron-guard enable {agent_id}` を使用。

### 7. 既存機能への影響

- [PASS] `cmd_done()` 内のチェックポイント処理 cron 操作コード（`mc:818-836`）: 変更なし。引き続き `openclaw cron disable` を直接使用（Tier 1 の変更対象外）。
- [PASS] `cmd_mission() pause/resume` 内の cron 操作コード（`mc:362-418`）: 変更なし。引き続き `openclaw cron` を直接使用（Tier 1 の変更対象外）。
- [PASS] `cmd_mission() complete` 内の cron 操作コード（`mc:278-359`）: 変更なし。
- [PASS] `set -euo pipefail` との整合性: `cmd_cron_guard` 内で cron_id が見つからない場合は `return 0` で正常終了。disable/enable 失敗時は `||` で代替メッセージを出力し、関数自体はエラー終了しない設計。

---

## 発見した問題点

なし（機能に影響する問題は発見されなかった）

---

## 推奨改善（非必須）

### 改善 1: テンプレート内の `$cron_id` 残存テキスト

- **ファイル**: `agents/templates/base.md:29`, `brain.md:27`, `monitor.md:27`, `escalator.md:46`
- **内容**: 全4テンプレートに以下のようなテキストが残っている:
  ```
  **IMPORTANT**: `$cron_id` is only available within this code block. In later steps, you must **re-derive the cron_id** inline.
  ```
- **問題**: `mc cron-guard` コマンドに置換された現在、`$cron_id` 変数は存在せず、この注意書きは無意味。LLM がこのテキストを読んで混乱する可能性がある。
- **修正提案**: 全4テンプレートからこの行を削除する。

### 改善 2: テンプレート内の `openclaw cron` コマンド失敗への言及テキスト

- **ファイル**: `agents/templates/base.md:27`, `brain.md:25,207`, `monitor.md:25`, `escalator.md:44`
- **内容**: 以下のようなテキストが残っている:
  ```
  **If `openclaw --profile "$OPENCLAW_PROFILE" cron` commands fail** (gateway timeout, SIGKILL, etc.), **skip the Cron Guard and continue with the workflow**.
  ```
- **問題**: 現在の Cron Guard は `mc cron-guard` コマンドであり、`openclaw cron` コマンドを直接実行しない。この注意書きは `mc cron-guard が失敗した場合` に書き換えるべき。
- **修正提案**: 全テンプレートで `openclaw --profile "$OPENCLAW_PROFILE" cron` を `mc cron-guard` に書き換える。例:
  ```
  **If `mc cron-guard` fails**, skip and continue with the workflow. Cron Guard is a best-effort optimization.
  ```

### 改善 3: brain.md Step 7 の `openclaw cron` 失敗言及

- **ファイル**: `agents/templates/brain.md:207`
- **内容**:
  ```
  **If `openclaw --profile "$OPENCLAW_PROFILE" cron` commands fail**, skip this step. The monitor agent's Stale Agent Cron Recovery (Step 5d) will detect the disabled cron and re-enable it.
  ```
- **修正提案**: 改善 2 と同様に `mc cron-guard` に書き換える。

---

## まとめ

Tier 1 の主要な6つの変更（cron-guard コマンド追加、テンプレート置換、in_progress 再開ロジック、cron メッセージ最小化、冪等化、フォールバックテンプレート更新）は全て仕様通りに実装されている。

推奨改善として挙げた3点は、旧実装時代の注意テキスト（`$cron_id` 言及、`openclaw cron` コマンド失敗への言及）がテンプレート内に残存している cosmetic な問題であり、LLM の混乱リスクを低減するために削除・書き換えを推奨する。
