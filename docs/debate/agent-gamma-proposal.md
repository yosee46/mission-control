# Agent Gamma: 宣言的フロー定義 + 汎用エグゼキューター方式

## 仮説

現在の OMOS mc-architect は「LLM が Markdown に記述された手順を逐次記憶・実行する」設計であり、**フロー制御ロジック**（ステップ順序、前提条件、検証ルール）と**ドメインロジック**（ミッション分析、チーム設計、plan.md 作成）が AGENTS.md テンプレートという単一の自然言語ドキュメントに混在している。これにより、フロー自体の変更・テスト・検証が困難であり、LLM の「記憶係」としての不安定さが全ての障害の根本原因となっている。

**フロー定義とフロー実行を分離**し、フロー定義を宣言的データ（YAML）として外部化、フロー実行を決定論的な Python エンジンに委ねることで、LLM には「各ステップ内のドメイン判断」のみを任せる設計に転換すべきである。

---

## Alpha, Beta, C との位置付け

| Agent | アプローチ | 手段 | 限界 |
|-------|-----------|------|------|
| A（耐障害性） | 障害に備える | テンプレートにガードレール追加 | ガードレール自体が LLM の認知負荷を増やし、遵守率が低下するパラドックス |
| B（シンプリシティ） | 障害点を減らす | mc CLI にロジックを移動 | 個別コマンドの追加であり、ステップ間の前後関係・依存性の保証がない。フロー全体の整合性は依然として LLM の記憶に依存 |
| C（可観測性） | 障害を検知する | ログ・状態ファイル・検証ステップ追加 | 二重管理の増加、テンプレート肥大化。検知はするが構造的な予防にならない |
| **Gamma（宣言的）** | **障害が起きない構造を作る** | フロー定義をデータ化、実行をエンジン化 | 抽象化コスト、既存との乖離、学習コスト（後述で正直に分析） |

**Gamma の核心的な差異**: Alpha, Beta, C はいずれも「AGENTS.md テンプレートの改善」を軸にしている。テンプレートに行を追加するか（A, C）、テンプレートから行を削除して CLI に移すか（B）の違いであり、**「LLM がフロー制御を担う」前提自体は変えていない**。Gamma はこの前提を覆し、フロー制御を LLM から完全に取り上げる。

---

## 現状の構造的問題: なぜ「テンプレート改善」では不十分か

### 問題の再定式化

Agent A, B, C が指摘した個別の問題（Cron Guard 脆弱性、plan.md 破損リスク、Phase 管理の複雑さ等）は全て同一の根本原因から派生している:

**「フロー制御ロジックが自然言語で記述され、LLM がそれを解釈・実行する」**

```
現在の構造:
  AGENTS.md = フロー制御ロジック + ドメインロジック + 安全ルール + コマンドリファレンス
              ↓
  LLM が全てを読み込み、逐次実行
              ↓
  問題: フロー制御の実行精度が LLM の解釈精度に完全依存
```

Alpha の「ガードレール追加」は自然言語の指示を追加するだけなので、LLM の解釈精度に依存する問題を解決しない。Beta の「CLI コマンド化」は個別操作を決定論的にするが、ステップ間の順序制約（Step 3.7 の plan.md 作成は Step 4 の setup_mission より前でなければならない等）は依然として LLM の記憶に依存する。

### Gamma が解決する構造

```
Gamma の構造:
  flow.yaml = フロー制御ロジック（ステップ順序、入出力、検証ルール）
              ↓
  Python エンジン（flow_executor.py）が flow.yaml を解釈・実行
              ↓
  各ステップで LLM に「ドメイン判断」のみを委任
              ↓
  結果: フロー制御は決定論的、ドメイン判断は LLM
```

---

## 設計の全体像

### ファイル構成

```
mission-control/
├── flows/
│   ├── architect-new-mission.yaml    # mc-architect の新規ミッションフロー定義
│   ├── architect-course-correct.yaml # 方針変更フロー
│   └── architect-status-check.yaml   # 進捗確認フロー
├── tools/
│   ├── flow_executor.py              # 汎用フローエグゼキューター
│   ├── context_store.py              # 構造化コンテキストストア
│   ├── plan_parser.py                # plan.md のパース・バリデーション
│   ├── cron_helper.py                # Cron 操作の Python 化
│   └── setup_mission.py              # 既存（冪等性強化）
├── agents/
│   └── templates/
│       ├── base.md                   # Worker テンプレート（簡素化）
│       └── brain.md                  # Brain テンプレート（簡素化）
└── schemas/
    ├── flow.schema.json              # フロー定義の JSON Schema
    └── plan.schema.json              # plan.md フロントマターの JSON Schema
```

### 1. 宣言的フロー定義ファイル

mc-architect の全フローを YAML で宣言的に定義する。各ステップの入力・出力・前提条件・検証ルール・失敗時のハンドリングをデータとして記述する。

**なぜ YAML か**: Agent C が plan.md に YAML フロントマターを導入する提案を出し、Agent A, B がそれを批判した（「LLM に YAML を書かせるのは矛盾」）。しかし Gamma では **YAML を書くのは人間の開発者であり、LLM ではない**。フロー定義は OMOS のインフラコードであり、エージェントの実行時入力ではない。

```yaml
# flows/architect-new-mission.yaml
---
flow: architect-new-mission
description: "新規ミッションの設計・構成・起動フロー"
version: 1

context_schema:
  # フロー全体で共有されるコンテキスト変数の型定義
  profile:        { type: string, required: true }
  config_dir:     { type: string, required: true }
  project:        { type: string, required: true }
  mission:        { type: string, required: true }
  goal:           { type: string, required: true }
  slack_channel:  { type: string, required: true }
  slack_user_id:  { type: string, required: true }
  roles:          { type: "list[string]", required: true }
  plan_path:      { type: string, required: true }
  roles_json_path: { type: string, required: false }

steps:
  - id: detect_profile
    name: "Profile 検出"
    action: shell
    command: 'echo "OPENCLAW_PROFILE=$OPENCLAW_PROFILE"'
    extract:
      profile:
        pattern: 'OPENCLAW_PROFILE=(.+)'
        default: ""
    derive:
      config_dir: "~/.openclaw-{profile}" if profile else "~/.openclaw"
    validate:
      - expr: "profile != ''"
        error: "OPENCLAW_PROFILE が設定されていません"
    on_failure: abort

  - id: analyze_mission
    name: "ミッション分析"
    action: llm_judge
    prompt: |
      ユーザーのリクエストから以下を決定してください:
      - project: kebab-case のプロジェクト名（project:<name> 指定があればそれを使用）
      - mission: フェーズや目的を表す名前
      - goal: 目的の一行要約
      - slack_channel: メッセージヘッダーから抽出（Slack message in #CXXXXXXXX from UXXXXXXXX）
      - slack_user_id: 同上

      ユーザーリクエスト: {user_request}
    output_schema:
      project:      { type: string, pattern: "^[a-z0-9-]+$" }
      mission:      { type: string, pattern: "^[a-z0-9-]+$" }
      goal:         { type: string, min_length: 5 }
      slack_channel: { type: string, pattern: "^C[A-Z0-9]+$" }
      slack_user_id: { type: string, pattern: "^U[A-Z0-9]+$" }
    validate:
      - expr: "project != ''"
        error: "project 名が空です"
      - expr: "mission != ''"
        error: "mission 名が空です"
      - expr: "goal != ''"
        error: "goal が空です"
    on_failure: retry(max=2, then=abort)

  - id: design_team
    name: "チーム設計"
    action: llm_judge
    prompt: |
      ミッション要件に基づき、必要な role を決定してください。

      Project: {project}
      Mission: {mission}
      Goal: {goal}

      チームサイズ目安:
      - 小: 1-2 agents（coder + reviewer）
      - 中: 3-4 agents
      - 大: 4-6 agents（3 agents を超える場合は reviewer 必須）

      使える role 例: researcher, backend, frontend, coder, reviewer, analyst, content-writer
      任意の role を定義してよい。
    output_schema:
      roles: { type: "list[string]", min_items: 1, max_items: 6 }
    validate:
      - expr: "len(roles) >= 1"
        error: "最低1つの role が必要です"
      - expr: "len(roles) <= 3 or 'reviewer' in roles"
        error: "3 agent を超える場合は reviewer が必須です"
    on_failure: retry(max=2, then=abort)

  - id: design_role_specs
    name: "Role 仕様設計"
    action: llm_judge
    condition: "len(roles) > 1"  # 単一roleの場合はスキップ
    prompt: |
      各 role の specialization を定義してください。
      Roles: {roles}
      Goal: {goal}

      JSON形式で出力:
      {{"roles": {{"<role>": {{"description": "...", "specialization": "..."}}}}}}
    output_schema:
      roles_json: { type: object }
    output_file: "/tmp/{project}-roles.json"
    on_failure: skip  # roles.json は任意

  - id: create_plan
    name: "plan.md 作成"
    action: llm_generate
    prompt: |
      以下のミッションに対する plan.md を作成してください。

      Project: {project}
      Mission: {mission}
      Goal: {goal}
      Roles: {roles}
      今日の日付: {today}

      plan.md フォーマット（厳守）:
      ```
      # Mission Plan: <mission-name>
      ## Goal
      <goal>
      ## Agents
      - <role>: <概要>
      ## Phase 1: <name>
      Timeline: Day 0
      Auto: true
      ### Tasks
      - [ ] タスク説明 @role [P0-2]
      ### Success Criteria
      - <条件>
      ```

      制約:
      - Phase 1 は必ず Auto: true
      - 1 Phase あたりタスク 3-7 件
      - 相対タイムライン ("Day 2") は今日を基準に絶対日時に変換
    output_file: "/tmp/{project}-plan.md"
    validate:
      - type: file_exists
        path: "/tmp/{project}-plan.md"
      - type: file_not_empty
        path: "/tmp/{project}-plan.md"
      - type: content_contains
        path: "/tmp/{project}-plan.md"
        pattern: "## Goal"
      - type: content_contains
        path: "/tmp/{project}-plan.md"
        pattern: "## Phase 1"
      - type: content_contains
        path: "/tmp/{project}-plan.md"
        pattern: "Auto: true"
      - type: plan_roles_match
        path: "/tmp/{project}-plan.md"
        expected_roles: "{roles}"
    on_failure: retry(max=2, then=abort)
    save_context:
      plan_path: "/tmp/{project}-plan.md"

  - id: user_approval
    name: "ユーザー承認"
    action: user_confirm
    present:
      template: |
        :clipboard: ミッションプラン作成しました。レビューをお願いします。

        **Project**: {project}
        **Mission**: {mission}
        **Goal**: {goal}

        **チーム構成**:
        {roles_summary}

        {plan_summary}

        このプランで進めてよいですか？
        修正が必要な場合は具体的にお知らせください。
    on_approve: continue
    on_reject: goto(create_plan)  # plan 再作成
    on_cancel: abort

  - id: execute_setup
    name: "setup_mission 実行"
    action: shell
    command: |
      setup_mission {project} {mission} "{goal}" \
        --roles {roles_csv} \
        --slack-channel {slack_channel} \
        --slack-user-id {slack_user_id} \
        --plan {plan_path} \
        --profile {profile} \
        {roles_json_flag}
    validate:
      - type: exit_code
        expected: 0
      - type: output_not_contains
        pattern: "ERROR"
    on_failure: retry(max=1, then=abort_with_report)

  - id: launch_brain
    name: "brain 委任"
    action: shell
    condition: "setup_success"
    command: 'openclaw --profile {profile} agent --agent {project}-{mission}-brain -m "Read your AGENTS.md and execute your workflow."'
    on_failure: skip  # brain の即時起動は任意

  - id: report_completion
    name: "完了報告"
    action: llm_generate
    prompt: |
      ミッション起動完了を報告してください。以下の情報を含むこと:
      - Project: {project}
      - Mission: {mission}
      - チーム: {roles}
      - brain が plan.md を読み、Phase 1 タスクを自動作成すること
      - 進捗確認コマンド: mc -p {project} -m {mission} board
      - プラン確認: mc -p {project} plan show
      - 完了時: mc -p {project} -m {mission} mission complete
    output_channel: slack

# フロー全体のエラーハンドリング
error_handling:
  abort_with_report:
    action: slack_notify
    message: |
      :warning: ミッション起動に失敗しました。
      Project: {project}
      Step: {current_step}
      Error: {last_error}
      手動で確認してください。
```

**なぜこの設計か（他アプローチとの比較）**:

1. **vs Alpha（ガードレール）**: Alpha は `validate` 相当のチェックをテンプレートの自然言語として記述する。LLM が検証を「実行するかどうか」が不確実。Gamma では `validate` はエンジンが**強制的に**実行するため、スキップされない。

2. **vs Beta（CLI コマンド化）**: Beta は `mc cron-guard`, `mc phase status` 等の個別コマンドを追加する。これは正しい方向だが、コマンドの**呼び出し順序**は依然として LLM に委ねている。Gamma では順序がフロー定義に宣言されており、エンジンが保証する。

3. **vs C（可観測性）**: C は decision-log.jsonl を LLM に echo で書かせる。Gamma ではエンジンが各ステップの実行結果を自動的にログに記録する（後述の context_store）。LLM は何もしなくてよい。

### 2. 汎用フローエグゼキューター

フロー定義を読み取り、ステップごとに実行・検証する Python エンジン。

```python
# tools/flow_executor.py
"""
汎用フローエグゼキューター: YAML フロー定義を読み取り、
ステップごとに実行・検証する。

設計原則:
- フロー制御は決定論的（Python エンジン）
- ドメイン判断は LLM に委任（action: llm_judge / llm_generate）
- 各ステップの入出力はコンテキストストアで永続化
- 検証ルールはエンジンが強制実行（LLM がスキップ不可能）
"""

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml  # PyYAML が必要

from context_store import ContextStore


class FlowExecutor:
    """YAML フロー定義を解釈・実行するエンジン。"""

    def __init__(self, flow_path: str, context_store: ContextStore):
        self.flow = yaml.safe_load(Path(flow_path).read_text())
        self.ctx = context_store
        self.current_step_id: str | None = None
        self.execution_log: list[dict] = []

    def run(self, initial_context: dict[str, Any] | None = None) -> bool:
        """フロー全体を実行する。成功時 True、失敗時 False を返す。"""
        if initial_context:
            for k, v in initial_context.items():
                self.ctx.set(k, v)

        self.ctx.set("flow_name", self.flow["flow"])
        self.ctx.set("flow_started_at", datetime.now(timezone.utc).isoformat())

        steps = self.flow.get("steps", [])
        i = 0
        while i < len(steps):
            step = steps[i]
            self.current_step_id = step["id"]

            # 条件付きステップのスキップ判定
            if "condition" in step:
                if not self._evaluate_condition(step["condition"]):
                    self._log_step(step["id"], "skipped", "condition not met")
                    i += 1
                    continue

            print(f"\n{'='*60}")
            print(f"Step [{i+1}/{len(steps)}]: {step['name']} (id: {step['id']})")
            print(f"{'='*60}")

            success = self._execute_step(step)

            if success:
                self._log_step(step["id"], "completed", "")
                i += 1
            else:
                action = self._handle_failure(step)
                if action == "abort":
                    self._log_step(step["id"], "aborted", self.ctx.get("last_error", ""))
                    self._execute_error_handling()
                    return False
                elif action == "retry":
                    self._log_step(step["id"], "retrying", self.ctx.get("last_error", ""))
                    continue  # 同じ step を再実行
                elif action == "skip":
                    self._log_step(step["id"], "skipped_on_failure", self.ctx.get("last_error", ""))
                    i += 1
                elif action.startswith("goto("):
                    target = action[5:-1]
                    target_idx = next(
                        (j for j, s in enumerate(steps) if s["id"] == target), None
                    )
                    if target_idx is not None:
                        self._log_step(step["id"], "goto", target)
                        i = target_idx
                    else:
                        print(f"ERROR: goto target '{target}' not found")
                        return False

        self.ctx.set("flow_completed_at", datetime.now(timezone.utc).isoformat())
        self._save_execution_log()
        return True

    def _execute_step(self, step: dict) -> bool:
        """単一ステップを実行する。"""
        action = step.get("action", "")

        try:
            if action == "shell":
                return self._action_shell(step)
            elif action == "llm_judge":
                return self._action_llm_judge(step)
            elif action == "llm_generate":
                return self._action_llm_generate(step)
            elif action == "user_confirm":
                return self._action_user_confirm(step)
            else:
                print(f"ERROR: Unknown action type: {action}")
                return False
        except Exception as e:
            self.ctx.set("last_error", str(e))
            print(f"ERROR in step '{step['id']}': {e}")
            return False

    def _action_shell(self, step: dict) -> bool:
        """シェルコマンドを実行し、結果をコンテキストに保存。"""
        command = self._render_template(step["command"])
        print(f"  Running: {command[:100]}...")

        result = subprocess.run(
            command, shell=True, capture_output=True, text=True
        )

        self.ctx.set("last_exit_code", result.returncode)
        self.ctx.set("last_stdout", result.stdout.strip())
        self.ctx.set("last_stderr", result.stderr.strip())

        # extract: 正規表現でコンテキスト変数を抽出
        for key, spec in step.get("extract", {}).items():
            match = re.search(spec["pattern"], result.stdout)
            if match:
                self.ctx.set(key, match.group(1))
            elif "default" in spec:
                self.ctx.set(key, spec["default"])

        # derive: コンテキスト変数から派生値を計算
        for key, expr in step.get("derive", {}).items():
            value = self._evaluate_derive(expr)
            self.ctx.set(key, value)

        # validate
        return self._run_validations(step.get("validate", []))

    def _action_llm_judge(self, step: dict) -> bool:
        """LLM にドメイン判断を委任し、構造化された出力を受け取る。

        NOTE: 実際の LLM 呼び出しは mc-architect セッション内で行われる。
        このメソッドは「LLM にどのプロンプトを渡し、どの形式で出力を受け取るか」
        を制御するインターフェースを定義する。
        """
        prompt = self._render_template(step["prompt"])
        output_schema = step.get("output_schema", {})

        print(f"  LLM Judge: {step['name']}")
        print(f"  Prompt: {prompt[:200]}...")
        print(f"  Expected output: {list(output_schema.keys())}")

        # 実際の実装では、ここで LLM API を呼び出すか、
        # mc-architect のセッション内でプロンプトを提示して応答を待つ。
        # PoC ではインタラクティブ入力で代替:
        print(f"\n  [LLM に以下を判断してもらう]")
        print(f"  {prompt}")
        print(f"\n  出力を JSON で入力してください:")
        raw = input("  > ").strip()

        try:
            output = json.loads(raw)
        except json.JSONDecodeError as e:
            self.ctx.set("last_error", f"JSON parse error: {e}")
            return False

        # output_schema に基づくバリデーション
        for key, schema in output_schema.items():
            if key not in output:
                self.ctx.set("last_error", f"Missing key: {key}")
                return False
            value = output[key]
            if "pattern" in schema:
                if not re.match(schema["pattern"], str(value)):
                    self.ctx.set("last_error", f"{key} doesn't match pattern {schema['pattern']}: {value}")
                    return False
            self.ctx.set(key, value)

        # save_context
        for key, value in step.get("save_context", {}).items():
            self.ctx.set(key, self._render_template(value))

        return self._run_validations(step.get("validate", []))

    def _action_llm_generate(self, step: dict) -> bool:
        """LLM にファイルを生成させる。"""
        prompt = self._render_template(step["prompt"])
        output_file = self._render_template(step.get("output_file", ""))

        print(f"  LLM Generate: {step['name']}")
        print(f"  Output: {output_file}")

        # 実際の実装では LLM API を呼び出す
        print(f"\n  [LLM にファイルを生成してもらう]")
        print(f"  {prompt[:500]}...")
        print(f"\n  ファイル内容を入力 (END_INPUT で終了):")
        lines = []
        while True:
            line = input()
            if line.strip() == "END_INPUT":
                break
            lines.append(line)

        content = "\n".join(lines)
        if output_file:
            Path(output_file).parent.mkdir(parents=True, exist_ok=True)
            Path(output_file).write_text(content)
            self.ctx.set("last_generated_file", output_file)

        # save_context
        for key, value in step.get("save_context", {}).items():
            self.ctx.set(key, self._render_template(value))

        return self._run_validations(step.get("validate", []))

    def _action_user_confirm(self, step: dict) -> bool:
        """ユーザーに確認を求め、承認/拒否/キャンセルを受け付ける。"""
        message = self._render_template(step["present"]["template"])
        print(f"\n{message}")
        print(f"\n  [approve/reject/cancel]: ", end="")
        response = input().strip().lower()

        if response in ("approve", "ok", "y", "yes"):
            return True
        elif response in ("reject", "no", "n"):
            self.ctx.set("user_action", "reject")
            return False
        else:
            self.ctx.set("user_action", "cancel")
            return False

    def _run_validations(self, validations: list[dict]) -> bool:
        """検証ルールを実行する。全て通過で True。"""
        for v in validations:
            if "expr" in v:
                # Python 式を評価（コンテキスト変数を使用）
                try:
                    result = eval(v["expr"], {"__builtins__": {}}, self.ctx.as_dict())
                except Exception as e:
                    self.ctx.set("last_error", f"Validation expr error: {v['expr']} -> {e}")
                    print(f"  FAIL: {v.get('error', v['expr'])}")
                    return False
                if not result:
                    self.ctx.set("last_error", v.get("error", f"Validation failed: {v['expr']}"))
                    print(f"  FAIL: {v.get('error', v['expr'])}")
                    return False
            elif v.get("type") == "file_exists":
                path = self._render_template(v["path"])
                if not Path(path).exists():
                    self.ctx.set("last_error", f"File not found: {path}")
                    return False
            elif v.get("type") == "file_not_empty":
                path = self._render_template(v["path"])
                if not Path(path).exists() or Path(path).stat().st_size == 0:
                    self.ctx.set("last_error", f"File empty or missing: {path}")
                    return False
            elif v.get("type") == "content_contains":
                path = self._render_template(v["path"])
                pattern = v["pattern"]
                content = Path(path).read_text() if Path(path).exists() else ""
                if pattern not in content:
                    self.ctx.set("last_error", f"'{pattern}' not found in {path}")
                    return False
            elif v.get("type") == "exit_code":
                if self.ctx.get("last_exit_code") != v.get("expected", 0):
                    self.ctx.set("last_error", f"Exit code {self.ctx.get('last_exit_code')} != {v.get('expected', 0)}")
                    return False
            # 追加の検証タイプはここに拡張
            print(f"  PASS: {v.get('type', v.get('expr', ''))[:60]}")
        return True

    def _handle_failure(self, step: dict) -> str:
        """失敗時のハンドリング。on_failure の値に基づいてアクションを決定。"""
        on_failure = step.get("on_failure", "abort")

        if on_failure == "abort":
            return "abort"
        elif on_failure == "skip":
            return "skip"
        elif on_failure.startswith("retry"):
            # retry(max=2, then=abort)
            max_retries = int(re.search(r"max=(\d+)", on_failure).group(1))
            then_action = re.search(r"then=(\w+)", on_failure)
            then_action = then_action.group(1) if then_action else "abort"

            retry_key = f"_retry_count_{step['id']}"
            current = self.ctx.get(retry_key, 0)
            if current < max_retries:
                self.ctx.set(retry_key, current + 1)
                return "retry"
            else:
                return then_action
        elif on_failure.startswith("goto("):
            return on_failure
        elif on_failure == "abort_with_report":
            return "abort"  # abort 後に error_handling が実行される
        return "abort"

    def _render_template(self, template: str) -> str:
        """テンプレート文字列のコンテキスト変数を展開する。"""
        result = template
        for key, value in self.ctx.as_dict().items():
            if isinstance(value, list):
                result = result.replace(f"{{{key}}}", ", ".join(str(v) for v in value))
                result = result.replace(f"{{{key}_csv}}", ",".join(str(v) for v in value))
            else:
                result = result.replace(f"{{{key}}}", str(value))
        # today の特殊変数
        result = result.replace("{today}", datetime.now().strftime("%Y-%m-%d"))
        return result

    def _evaluate_condition(self, condition: str) -> bool:
        """条件式を評価する。"""
        try:
            return bool(eval(condition, {"__builtins__": {"len": len}}, self.ctx.as_dict()))
        except Exception:
            return False

    def _evaluate_derive(self, expr: str) -> str:
        """派生値を計算する。簡易的な条件式をサポート。"""
        ctx = self.ctx.as_dict()
        # "~/.openclaw-{profile}" if profile else "~/.openclaw" のようなパターン
        try:
            return str(eval(f'f"{expr}"' if "{" in expr else expr,
                           {"__builtins__": {}}, ctx))
        except Exception:
            return self._render_template(expr)

    def _execute_error_handling(self):
        """フロー全体のエラーハンドリングを実行する。"""
        handling = self.flow.get("error_handling", {})
        abort_config = handling.get("abort_with_report", {})
        if abort_config:
            message = self._render_template(abort_config.get("message", "Flow aborted"))
            print(f"\n[ERROR HANDLING] {message}")

    def _log_step(self, step_id: str, status: str, detail: str):
        """ステップの実行結果をログに記録する。"""
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "step": step_id,
            "status": status,
            "detail": detail,
        }
        self.execution_log.append(entry)
        print(f"  [{status.upper()}] {step_id} {detail}")

    def _save_execution_log(self):
        """実行ログをファイルに保存する。"""
        project = self.ctx.get("project", "unknown")
        config_dir = self.ctx.get("config_dir", "")
        if config_dir:
            log_dir = Path(config_dir).expanduser() / "projects" / project
            log_dir.mkdir(parents=True, exist_ok=True)
            log_path = log_dir / "flow-execution-log.jsonl"
            with open(log_path, "a") as f:
                for entry in self.execution_log:
                    entry["flow"] = self.flow.get("flow", "unknown")
                    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            print(f"\n  Execution log saved: {log_path}")
```

**なぜ汎用エンジンか**: mc-architect 固有のフロー定義だけでなく、将来的に brain, monitor 等のワークフローも宣言的に定義できる。フロー定義ファイルを差し替えるだけで異なるワークフローを実行できる柔軟性がある。

### 3. 構造化コンテキストストア

フロー実行中のコンテキスト（profile, project名等）を JSON ファイルに永続化する。LLM の「記憶係」問題を根本的に解決する。

```python
# tools/context_store.py
"""
構造化コンテキストストア: フロー実行中のコンテキスト変数を
JSON ファイルに永続化する。

設計原理:
- LLM のメモリに依存せず、ファイルシステムに状態を永続化
- 各ステップが読み書きすることで、セッション間の状態引き継ぎが可能
- スキーマ検証により、不正な値の書き込みを防止
"""

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class ContextStore:
    """JSON ファイルベースのコンテキストストア。"""

    def __init__(self, store_path: str | None = None):
        """
        Args:
            store_path: JSON ファイルのパス。None の場合はインメモリのみ。
        """
        self._data: dict[str, Any] = {}
        self._store_path = Path(store_path) if store_path else None
        self._history: list[dict] = []

        if self._store_path and self._store_path.exists():
            self._data = json.loads(self._store_path.read_text())

    def get(self, key: str, default: Any = None) -> Any:
        """コンテキスト変数を取得する。"""
        return self._data.get(key, default)

    def set(self, key: str, value: Any) -> None:
        """コンテキスト変数を設定し、永続化する。"""
        old_value = self._data.get(key)
        self._data[key] = value
        self._data["_last_updated"] = datetime.now(timezone.utc).isoformat()

        # 変更履歴を記録
        self._history.append({
            "ts": datetime.now(timezone.utc).isoformat(),
            "key": key,
            "old": old_value,
            "new": value,
        })

        self._persist()

    def as_dict(self) -> dict[str, Any]:
        """全コンテキスト変数を辞書として返す。"""
        return {k: v for k, v in self._data.items() if not k.startswith("_")}

    def get_history(self, key: str | None = None) -> list[dict]:
        """変更履歴を返す。key 指定時はそのキーの履歴のみ。"""
        if key:
            return [h for h in self._history if h["key"] == key]
        return self._history

    def _persist(self) -> None:
        """JSON ファイルに永続化する。"""
        if self._store_path:
            self._store_path.parent.mkdir(parents=True, exist_ok=True)
            # 安全な書き込み: tmp -> rename
            tmp_path = self._store_path.with_suffix(".tmp")
            tmp_path.write_text(json.dumps(self._data, indent=2, ensure_ascii=False))
            tmp_path.rename(self._store_path)

    def clear(self) -> None:
        """コンテキストをクリアする。"""
        self._data = {}
        self._history = []
        self._persist()
```

**なぜ JSON か**: YAML フロントマターへの Agent A, B の批判を踏まえ、構造化データの書き込みは Python コードが行う。LLM に JSON を書かせることはない。コンテキストストアの読み書きはエンジンが自動的に行い、LLM からは見えない。

### 4. Cron 操作の Python 化

Agent B の Cron Guard CLI 化提案を発展させ、bash one-liner を完全に Python モジュールに置き換える。

```python
# tools/cron_helper.py
"""
Cron 操作ヘルパー: bash one-liner を Python に置き換え。

Agent B が提案した `mc cron-guard disable/enable` の実体。
全テンプレートで 13 回コピーされていた bash one-liner を
1つの Python 関数に集約する。

設計原理:
- LLM は `mc cron-guard disable agent-id` を1行呼ぶだけ
- JSON パース、cron_id 取得、enable/disable は Python 内で完結
- エラーはベストエフォートで握りつぶす（Cron Guard の設計意図を維持）
"""

import json
import os
import subprocess
import sys
from typing import Optional


def get_cron_id(agent_name: str, profile: Optional[str] = None) -> Optional[str]:
    """エージェント名から cron job ID を取得する。"""
    profile = profile or os.environ.get("OPENCLAW_PROFILE", "")
    profile_flag = f"--profile {profile}" if profile else ""

    try:
        result = subprocess.run(
            f"openclaw {profile_flag} cron list --json",
            shell=True, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return None

        data = json.loads(result.stdout)
        for job in data.get("jobs", []):
            if job.get("name") == agent_name:
                return job.get("id")
    except (json.JSONDecodeError, subprocess.TimeoutExpired, Exception):
        return None

    return None


def cron_guard_disable(agent_name: str, profile: Optional[str] = None) -> bool:
    """
    エージェントの cron を無効化する（Cron Guard の前半）。

    失敗してもベストエフォートで True を返す。
    Cron Guard の失敗はワークフローをブロックしない。
    """
    profile = profile or os.environ.get("OPENCLAW_PROFILE", "")
    profile_flag = f"--profile {profile}" if profile else ""

    cron_id = get_cron_id(agent_name, profile)
    if not cron_id:
        print(f"[CRON_GUARD] {agent_name}: cron_id not found (best-effort skip)")
        return True  # ベストエフォート

    try:
        result = subprocess.run(
            f"openclaw {profile_flag} cron disable {cron_id}",
            shell=True, capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            print(f"[CRON_GUARD] {agent_name}: cron disabled")
            return True
        else:
            print(f"[CRON_GUARD] {agent_name}: disable failed (best-effort skip)")
            return True
    except (subprocess.TimeoutExpired, Exception) as e:
        print(f"[CRON_GUARD] {agent_name}: error {e} (best-effort skip)")
        return True


def cron_guard_enable(agent_name: str, profile: Optional[str] = None) -> bool:
    """
    エージェントの cron を再有効化する（Cron Guard の後半）。
    """
    profile = profile or os.environ.get("OPENCLAW_PROFILE", "")
    profile_flag = f"--profile {profile}" if profile else ""

    cron_id = get_cron_id(agent_name, profile)
    if not cron_id:
        print(f"[CRON_GUARD] {agent_name}: cron_id not found for enable")
        return False

    try:
        result = subprocess.run(
            f"openclaw {profile_flag} cron enable {cron_id}",
            shell=True, capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            print(f"[CRON_GUARD] {agent_name}: cron re-enabled")
            return True
        else:
            print(f"[CRON_GUARD] {agent_name}: enable failed")
            return False
    except (subprocess.TimeoutExpired, Exception) as e:
        print(f"[CRON_GUARD] {agent_name}: error {e}")
        return False


def main():
    """CLI エントリポイント: mc cron-guard disable/enable <agent-name>"""
    if len(sys.argv) < 3:
        print("Usage: cron_helper.py <disable|enable> <agent-name> [--profile <profile>]")
        sys.exit(1)

    action = sys.argv[1]
    agent_name = sys.argv[2]
    profile = None
    if "--profile" in sys.argv:
        idx = sys.argv.index("--profile")
        if idx + 1 < len(sys.argv):
            profile = sys.argv[idx + 1]

    if action == "disable":
        cron_guard_disable(agent_name, profile)
    elif action == "enable":
        cron_guard_enable(agent_name, profile)
    else:
        print(f"Unknown action: {action}")
        sys.exit(1)


if __name__ == "__main__":
    main()
```

### 5. plan.md のバリデーター

Agent C の YAML フロントマター提案と Agent A, B の批判を踏まえ、**plan.md はMarkdown のまま維持しつつ、Python コードでパース・バリデーションする**方式を採用する。

```python
# tools/plan_parser.py
"""
plan.md パーサー & バリデーター

plan.md は Markdown のまま維持（人間可読性を優先）し、
Python コードで構造化解析とバリデーションを行う。

これにより:
- Agent C の「plan.md の解釈保証」を実現
- Agent A, B の「LLM に YAML/JSON を書かせない」原則を尊重
- Agent B の「mc phase create-tasks」の基盤を提供
"""

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class PlanTask:
    """plan.md 内のタスク定義。"""
    subject: str
    role: str
    priority: int = 1
    task_type: str = "normal"  # normal | checkpoint
    scheduled_at: Optional[str] = None  # "YYYY-MM-DD HH:MM"
    completed: bool = False
    task_id: Optional[str] = None  # mc 上のタスクID（brain がアノテーション後）


@dataclass
class PlanPhase:
    """plan.md 内のフェーズ定義。"""
    number: int
    name: str
    timeline: str = ""
    auto: bool = False
    proposed: bool = False
    tasks: list[PlanTask] = field(default_factory=list)
    success_criteria: list[str] = field(default_factory=list)


@dataclass
class MissionPlan:
    """plan.md 全体の構造化表現。"""
    mission_name: str
    goal: str
    agents: dict[str, str] = field(default_factory=dict)  # role -> description
    phases: list[PlanPhase] = field(default_factory=list)


def parse_plan(plan_path: str) -> MissionPlan:
    """plan.md を解析して MissionPlan を返す。"""
    content = Path(plan_path).read_text()
    lines = content.split("\n")

    plan = MissionPlan(mission_name="", goal="")
    current_phase: Optional[PlanPhase] = None
    current_section: str = ""  # "tasks" | "criteria" | ""

    for line in lines:
        stripped = line.strip()

        # Mission Plan タイトル
        m = re.match(r"^# Mission Plan:\s*(.+)$", stripped)
        if m:
            plan.mission_name = m.group(1).strip()
            continue

        # Goal
        if stripped == "## Goal":
            current_section = "goal"
            continue
        if current_section == "goal" and stripped and not stripped.startswith("#"):
            plan.goal = stripped
            current_section = ""
            continue

        # Agents
        if stripped == "## Agents":
            current_section = "agents"
            continue
        if current_section == "agents" and stripped.startswith("- "):
            m = re.match(r"^- (\w[\w-]*):\s*(.+)$", stripped)
            if m:
                plan.agents[m.group(1)] = m.group(2)
            continue
        if current_section == "agents" and stripped.startswith("##"):
            current_section = ""
            # fall through to phase detection

        # Phase
        m = re.match(r"^## Phase (\d+):\s*(.+?)(?:\s*\[PROPOSED\])?\s*$", stripped)
        if m:
            if current_phase:
                plan.phases.append(current_phase)
            phase_num = int(m.group(1))
            phase_name = m.group(2).strip()
            proposed = "[PROPOSED]" in stripped
            current_phase = PlanPhase(number=phase_num, name=phase_name, proposed=proposed)
            current_section = ""
            continue

        # Timeline
        if current_phase and stripped.startswith("Timeline:"):
            current_phase.timeline = stripped[len("Timeline:"):].strip()
            continue

        # Auto
        if current_phase and stripped.startswith("Auto:"):
            current_phase.auto = stripped.lower().endswith("true")
            continue

        # Tasks section
        if stripped == "### Tasks":
            current_section = "tasks"
            continue

        # Success Criteria section
        if stripped == "### Success Criteria":
            current_section = "criteria"
            continue

        # Task line
        if current_section == "tasks" and current_phase:
            m = re.match(r"^- \[([ xX])\]\s+(.+)$", stripped)
            if m:
                completed = m.group(1).lower() == "x"
                task_text = m.group(2)
                task = _parse_task_line(task_text, completed)
                current_phase.tasks.append(task)
                continue

        # Success criteria line
        if current_section == "criteria" and current_phase:
            if stripped.startswith("- "):
                current_phase.success_criteria.append(stripped[2:])
                continue

    # 最後のフェーズを追加
    if current_phase:
        plan.phases.append(current_phase)

    return plan


def _parse_task_line(text: str, completed: bool) -> PlanTask:
    """タスク行をパースする。例: 'タスク説明 @role [P0] --at "2026-02-20 09:00" --type checkpoint'"""
    task = PlanTask(subject="", role="", completed=completed)

    # --type checkpoint
    if "--type checkpoint" in text:
        task.task_type = "checkpoint"
        text = text.replace("--type checkpoint", "").strip()

    # --at "datetime"
    at_match = re.search(r'--at\s+"([^"]+)"', text)
    if at_match:
        task.scheduled_at = at_match.group(1)
        text = re.sub(r'--at\s+"[^"]+"', "", text).strip()

    # [P0], [P1], [P2]
    p_match = re.search(r"\[P(\d)\]", text)
    if p_match:
        task.priority = int(p_match.group(1))
        text = re.sub(r"\[P\d\]", "", text).strip()

    # @role (最後の @word を取得)
    role_match = re.search(r"@([\w-]+)", text)
    if role_match:
        task.role = role_match.group(1)
        text = re.sub(r"@[\w-]+", "", text).strip()

    # 残りがタスク説明
    # task-id アノテーション除去: "→ #42" のようなサフィックス
    text = re.sub(r"\s*→\s*#\d+$", "", text).strip()
    task.subject = text

    return task


def validate_plan(plan: MissionPlan, expected_roles: list[str]) -> list[str]:
    """plan を検証し、警告リストを返す。"""
    warnings: list[str] = []

    if not plan.goal:
        warnings.append("Goal が空です")

    if not plan.phases:
        warnings.append("Phase が定義されていません")

    # Phase 1 の Auto: true チェック
    if plan.phases and not plan.phases[0].auto:
        warnings.append("Phase 1 に Auto: true が設定されていません")

    for phase in plan.phases:
        # タスク数チェック
        if len(phase.tasks) == 0:
            warnings.append(f"Phase {phase.number} にタスクがありません")
        if len(phase.tasks) > 7:
            warnings.append(f"Phase {phase.number} のタスクが {len(phase.tasks)} 件（推奨上限: 7）")

        # Success Criteria チェック
        if not phase.success_criteria:
            warnings.append(f"Phase {phase.number} に Success Criteria がありません")

        # role の整合性チェック
        for task in phase.tasks:
            if task.role and task.role not in expected_roles:
                warnings.append(
                    f"Phase {phase.number} のタスク '{task.subject}' が "
                    f"未知の role '{task.role}' を参照しています "
                    f"(期待: {expected_roles})"
                )

    return warnings
```

### 6. 簡素化されたエージェントテンプレート

フロー制御と Cron Guard がエンジン/CLI に移ったことで、テンプレートは大幅に簡素化される。

```markdown
# {agent_id}

## Identity
You are **{agent_id}**, a {role_description}, working on project **{project}**.

## Mission Context
- **Project**: {project}
- **Mission**: {mission}
- **Goal**: {goal}
- **Working Directory**: {config_dir}/projects/{project}/
- **Role**: {role}

{role_specialization}

## Workflow

### 0. Cron Guard
```bash
mc cron-guard disable {agent_id}
```
If this fails, skip and continue.

### 1. Check In
```bash
mc -p {project} -m {mission} checkin
```
If PAUSED/COMPLETED/ARCHIVED: `mc cron-guard enable {agent_id}` and stop.

### 2. Resume or Find Work
Check for in-progress tasks from a previous session:
```bash
mc -p {project} -m {mission} list --mine --status in_progress
```
If found, resume it. Otherwise:
```bash
mc -p {project} -m {mission} list --mine --status pending
```
If no assigned tasks:
```bash
mc -p {project} -m {mission} list --status pending
```

### 3. Claim and Execute
```bash
mc -p {project} -m {mission} claim <id>
mc -p {project} -m {mission} start <id>
```
Do the work. Then:
```bash
mc -p {project} -m {mission} done <id> -m "what was accomplished"
```

### 4. Next or Stop
If more tasks: go to Step 2.
If no tasks: `mc cron-guard enable {agent_id}` and stop.

## Communication
- Ask teammate: `mc -p {project} -m {mission} msg <agent> "question" --type question`
- Report blocker: `mc -p {project} -m {mission} msg {project}-{mission}-brain "blocked on X" --type alert`
- Request human input: `mc -p {project} -m {mission} add "Human: <request>" --for {project}-{mission}-escalator`
```

**行数比較**:

| テンプレート | 現在 | Gamma 適用後 | 削減率 |
|---|---|---|---|
| base.md | 104行 | ~50行 | -52% |
| brain.md | 215行 | ~80行 (Phase管理CLI化含む) | -63% |
| monitor.md | 99行 | ~40行 (brain統合の場合は廃止) | -60% |
| escalator.md | 99行 | ~45行 | -55% |

---

## Alpha, Beta, C の優れた提案の取り込み

Gamma は他の3アプローチの提案を棄却するのではなく、フレームワークの中に**構造的に**取り込む。

### Agent A から取り込む提案

| 提案 | 取り込み方 |
|------|----------|
| in_progress タスク優先再開（提案1） | テンプレートの Step 2 に直接反映（上記テンプレート参照） |
| setup_mission 冪等化（提案3） | Python コードの改修としてそのまま採用 |
| plan.md 安全書き込み（提案2） | flow_executor の validate ステップとして実装。brain がではなくエンジンが書き込み検証を行う |
| brain-monitor 相互監視（提案4） | cron_helper.py 内で相互チェック関数として実装 |

### Agent B から取り込む提案

| 提案 | 取り込み方 |
|------|----------|
| Cron Guard CLI 化（提案1） | cron_helper.py としてそのまま採用 |
| Phase 管理 CLI 化（提案3） | plan_parser.py + mc CLI コマンドとして実装 |
| cron メッセージ最小化（提案6） | setup_mission.py の修正としてそのまま採用 |
| テンプレート DRY 化（提案5） | Gamma ではテンプレート自体が大幅に短くなるため、自然に達成される |
| Step 再番号付け（提案4） | フロー定義で管理されるため不要（Step 番号はフロー YAML の steps 配列で暗黙的に決まる） |

### Agent C から取り込む提案

| 提案 | 取り込み方 |
|------|----------|
| Decision Log（提案1） | flow_executor が自動的に execution-log.jsonl を記録。LLM に echo させない |
| plan.md 解釈保証（提案2の動機） | plan_parser.py が Python でパース。YAML フロントマターではなく Markdown パーサーで実現 |
| タスク作成検証（提案6） | flow_executor の validate ステップとして自動実行 |
| Plan Drift 検知（提案4） | plan_parser.py で plan と実際のタスクを比較する関数を提供 |

---

## 正直な弱点分析

Gamma アプローチには以下の弱点がある。隠さずに分析する。

### 弱点 1: 過度な抽象化のリスク

**問題**: YAML フロー定義 + Python エンジンという抽象層の追加は、「テンプレートに1行追加する」のと比べて圧倒的に複雑。flow_executor.py だけで 200 行以上の Python コードが必要。

**なぜこれが問題か**:
- 抽象化には「抽象化それ自体のバグ」というコストがある。flow_executor の validate ロジックにバグがあれば、全フローに影響する。
- YAML フロー定義の DSL（ドメイン特有言語）を設計・維持するコストがある。
- デバッグが難しくなる: 問題が「フロー定義の誤り」なのか「エンジンのバグ」なのか「LLM の出力」なのかの切り分けが3層になる。

**緩和策**:
- エンジンに対する単体テストを書く（テスト容易性は Gamma の強み）
- フロー定義の JSON Schema を提供し、YAML 編集時にバリデーションできるようにする
- 段階的に導入する: まず mc-architect のフローのみに適用し、brain/monitor への拡張は安定後

### 弱点 2: 既存システムとの乖離

**問題**: 現在の OMOS は「LLM が AGENTS.md を読んでワークフローを実行する」という openlaw のネイティブなパターンに乗っている。Gamma はこのパターンから逸脱し、Python エンジンがフロー制御を行う独自アーキテクチャになる。

**なぜこれが問題か**:
- openclaw の cron + AGENTS.md というエコシステムとの互換性が下がる
- mc-architect のフローだけが特別扱いになり、brain/monitor/worker は従来パターンのまま。二重パラダイムの混在。
- 将来 openclaw がフロー制御機能を提供した場合、独自エンジンが負債になる

**緩和策**:
- mc-architect のフローのみに限定して適用。brain/monitor/worker は Beta の提案（CLI コマンド化）でテンプレートを簡素化する。
- flow_executor は openclaw の外側で動作する独立ツールとして位置付け、openclaw の API 変更に依存しない。
- 将来 openclaw にフロー制御が入った場合は、YAML フロー定義を移行パスとして活用できる（宣言的定義は移行しやすい）。

### 弱点 3: 学習コスト

**問題**: 開発者が YAML フロー定義の DSL を理解し、フロー変更ができるようになるまでの学習コスト。現在の AGENTS.md は Markdown で書かれており、誰でも読み書きできる。

**なぜこれが問題か**:
- フロー変更のたびに YAML DSL の知識が必要
- エンジンのアクションタイプ（shell, llm_judge, llm_generate, user_confirm）の仕様を理解する必要がある
- デバッグには Python の知識も必要

**緩和策**:
- フロー定義は mc-architect の動作仕様書（mc-architect-spec.md）の「実行可能版」と位置付ける。仕様書とフロー定義が1対1対応するため、仕様書を理解できれば YAML も理解できる
- 十分なコメントとドキュメントを YAML 内に記述する
- よく使うパターン（shell実行+検証、LLM判断+スキーマ検証、ユーザー確認+goto）をスニペットとして提供

### 弱点 4: LLM との統合の難しさ

**問題**: flow_executor の `action: llm_judge` は「LLM API を呼び出す」と書いたが、実際には mc-architect は openclaw のエージェントセッション内で動作する。エンジンがセッション内の LLM に「プロンプトを渡して構造化出力を受け取る」仕組みは、現在の openclaw では提供されていない可能性が高い。

**なぜこれが問題か**:
- flow_executor を openclaw セッションの外で動かすと、LLM との対話手段が必要（API 直接呼び出し）
- openclaw セッション内で動かすと、エンジンと LLM の制御の切り替えが複雑
- 結局「LLM にフロー定義を読ませて従わせる」に戻ってしまうリスク

**緩和策**:
- **ハイブリッドアプローチ**: flow_executor は mc-architect セッションの**ガイドレール**として機能する。完全にエンジンが制御するのではなく、フロー定義を mc-architect の AGENTS.md に**構造化された形で**埋め込み、LLM がフローに従いやすくする。エンジンは事前・事後の検証レイヤーとして動作する。
- **段階的移行**: 最初はフロー定義を「仕様のドキュメント」として使い、validate 部分のみエンジンで実行。LLM のフロー実行は AGENTS.md 経由で従来通り行い、各ステップの出力をエンジンが検証する。

---

## 段階的導入計画

全てを一度に実装するのは非現実的。以下の段階で導入する。

### Phase 1: 基盤整備（他アプローチとの共通部分）
**工数**: 3-5 時間

全員が合意している改善を先に実施する:

1. **cron_helper.py の実装** (Agent B 提案1)
2. **base.md に in_progress 再開ロジック追加** (Agent A 提案1)
3. **cron メッセージの最小化** (Agent B 提案6)
4. **setup_mission.py の冪等化** (Agent A 提案3)

### Phase 2: パーサー・バリデーター導入
**工数**: 3-5 時間

1. **plan_parser.py の実装**: plan.md を Python でパース、バリデーション
2. **setup_mission.py に plan バリデーション統合**: `--plan` オプションで渡された plan.md を自動検証
3. **context_store.py の実装**: フロー実行中のコンテキスト永続化

### Phase 3: フロー定義のプロトタイプ
**工数**: 5-8 時間

1. **architect-new-mission.yaml の作成**: mc-architect の新規ミッションフローを宣言的に定義
2. **flow_executor.py のプロトタイプ**: validate ステップのみを自動実行するミニマルな実装
3. **mc-architect の AGENTS.md を簡素化**: フロー定義と対応する形にリファクタリング

### Phase 4: エンジンの本格実装（将来）
**工数**: 8-15 時間

1. **flow_executor.py の完全実装**: 全アクションタイプのサポート
2. **brain/monitor テンプレートのフロー定義化**: Worker 以外のエージェントにも宣言的フローを適用
3. **mc CLI への統合**: `mc flow run architect-new-mission` のようなコマンドで起動

---

## 結論: なぜ Gamma か

### 他アプローチとの比較まとめ

| 基準 | Alpha | Beta | C | Gamma |
|------|-------|------|---|-------|
| **フロー順序の保証** | LLM 依存 | LLM 依存 | LLM 依存 | **エンジンが保証** |
| **ステップ検証の強制** | 自然言語の指示 | CLI コマンド | ログ記録 | **エンジンが強制実行** |
| **テンプレート複雑度** | 増加 | 減少 | 増加 | **大幅に減少** |
| **新ステップ追加** | テンプレート編集 | CLI + テンプレート | テンプレート編集 | **YAML 1行追加** |
| **テスト容易性** | 困難 | 部分的 | 困難 | **高い（Python テスト）** |
| **可観測性** | なし | なし | 手動ログ | **自動ログ** |
| **導入コスト** | 低 | 中 | 中 | **高** |
| **長期保守コスト** | 高 | 中 | 高 | **低** |

### Gamma が最も適する条件

- mc-architect のフローが今後も変化・拡張される（新ステップ追加、フロー分岐の追加等）
- フローの正確性が事業上重要（ミッション起動の失敗が大きなコストになる）
- テスト容易性を重視する（フロー定義のユニットテストが書ける）
- 長期的な保守性を優先する

### Gamma が適さない条件

- OMOS が実験段階であり、フローが頻繁に根本的に変わる（YAML DSL が負債になる）
- 開発リソースが限られており、Python エンジンの開発・保守コストを支払えない
- openclaw が近い将来フロー制御機能を提供する予定がある

### 最終推奨

**Phase 1（基盤整備）は他アプローチと共通のため即座に実施する**。Gamma 固有の Phase 2-4 については、Phase 1 の効果を評価した上で、OMOS の成熟度と開発リソースに応じて判断すべきである。

重要なのは、Gamma のアイデアの核心 -- **「フロー制御を LLM から分離する」** -- は、YAML エンジンを完全に実装しなくても部分的に適用できるということだ。plan_parser.py による plan.md の構造化パースだけでも、brain の解釈精度は大幅に向上する。context_store.py による状態永続化だけでも、LLM の「記憶係」問題は緩和される。

全か無かではなく、Gamma の構成要素を**個別に**導入し、効果を検証しながら拡張していくのが現実的なパスである。
