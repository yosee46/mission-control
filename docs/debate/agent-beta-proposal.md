# Agent Beta: イベント駆動 + ガードレール + 防御的プログラミング方式

## 設計哲学

> **「既存フローを壊さず、安全性をレイヤーとして注入する」**

Alpha（Agent A）のステートマシン方式は「状態遷移を形式的に定義して強制する」アプローチを取る。これに対して本提案は、以下の3つの柱で設計する:

1. **ガードレール付きラッパー**: 既存の `setup_mission` や `mc` CLI の呼び出しを薄いラッパーで包み、前提条件を自動検証してから実行する
2. **コンテキストファイル方式**: LLM の記憶に依存せず、セッション間で状態を引き継ぐための永続化レイヤー
3. **防御的テンプレート**: 各テンプレート内に自己診断・自己検証のステップを最小限のコストで埋め込む

---

## Alpha のステートマシン方式との比較

### ステートマシンの問題

Alpha（Agent A）の耐障害性アプローチは暗黙的にステートマシンの発想を持っている: 各 Step に前提条件を定義し、遷移を管理し、障害時にロールバックする。これには本質的な問題がある:

1. **状態数の爆発**: mc-architect の Step 0-6 に加え、各ステップの成功/失敗/部分成功の組み合わせが発生する。Step 4（setup_mission）だけでも内部に6サブステップがあり、各サブステップ内に5つのサブサブステップがある。厳密なステートマシンはこの組み合わせ爆発に対処できない
2. **遷移の硬直性**: 新しい Step を追加するたびに遷移テーブル全体を見直す必要がある。`3 -> 3.5 -> 3.7 -> 3.8` という番号の混乱は、硬直的な遷移定義が有機的成長に対応できなかった証拠
3. **LLM に状態遷移を理解させる困難**: LLM は「今自分がどの状態にいるか」を宣言的に判定するのが苦手。「前回のセッションで Step 3.7 まで完了し、Step 3.8 で承認待ちになった」という状態を次のセッションで復元するのは、LLM の記憶依存と同じ問題

### ガードレール方式の優位性

本提案のガードレール方式は、ステートマシンとは根本的に異なるアプローチを取る:

| 観点 | ステートマシン | ガードレール方式 |
|------|-------------|---------------|
| **前提条件の検証** | 状態遷移テーブルで定義。遷移が許可されなければ拒否 | 各コマンドの実行前にプログラム的に前提条件をチェック |
| **新しいステップの追加** | 遷移テーブルの更新が必要 | 新しいガードレール関数を追加するだけ。他に影響なし |
| **部分障害からの回復** | ロールバック先の状態を定義する必要がある | 冪等なガードレール関数が「現在の状態を読んで、必要な処理だけ実行」する |
| **LLM の認知負荷** | 「自分が今どの状態にいるか」を常に意識する必要がある | 「コマンドを実行する。前提条件はコマンドが自動チェックする」だけ |

つまり、ガードレール方式は **既存のフローを変えずに安全性を注入できる**。mc-architect の Step 0-6 はそのまま。ただし各 Step で呼ぶコマンドが、内部で前提条件を検証してから実行するようになる。

### イベント駆動の拡張性

さらに、本提案はイベント駆動の考え方を取り入れる。ステートマシンが「許可された遷移」を定義するのに対し、イベント駆動は「何かが起きたら反応する」パターンで、新しいイベントの追加が容易:

- `mc` コマンドの実行が「イベント」を生成する
- ガードレール関数がイベントの前提条件を検証する（pre-hook）
- ログ関数がイベントの結果を記録する（post-hook）

これにより、新しい検証ロジックや新しいログ項目の追加が、既存のコードを変更することなく可能になる。

---

## 提案 1: コンテキストファイル方式 — LLM の記憶依存を排除

### 問題

mc-architect の最大の脆弱性は、Step 0 で検出した `OPENCLAW_PROFILE` の値を LLM が「記憶」し、後続のすべてのコマンドに手動で埋め込むことに依存している点。仕様書は「LLM 自身が persistent context」と明記しており（仕様書 Section 4）、これはセッション跨ぎで破綻する。

さらに、Step 3.8（承認待ち）でセッションが中断され、再開時に profile 値、project 名、mission 名、plan パス等を全て復元する必要がある。

### 解決策: `/tmp/<project>-context.json`

mc-architect のセッション情報を JSON ファイルに永続化し、各ステップが自動的に参照する。

**ファイル**: `/tmp/<project>-context.json`

```json
{
  "version": 1,
  "profile": "prod",
  "config_dir": "/Users/ogawa/.openclaw-prod",
  "project": "ec-site",
  "mission": "prototype",
  "goal": "Django EC site prototype with auth, product list, and cart",
  "slack_channel": "C0AD97HHZD3",
  "slack_user_id": "U016J4Q75PZ",
  "roles": ["researcher", "backend", "frontend", "reviewer"],
  "plan_path": "/tmp/ec-site-plan.md",
  "roles_json_path": null,
  "step_completed": {
    "profile_detection": "2026-02-20T10:00:00Z",
    "mission_analysis": "2026-02-20T10:01:00Z",
    "team_design": "2026-02-20T10:02:00Z",
    "plan_created": "2026-02-20T10:05:00Z",
    "user_approved": null,
    "setup_executed": null,
    "brain_delegated": null,
    "completion_reported": null
  },
  "created_at": "2026-02-20T10:00:00Z",
  "updated_at": "2026-02-20T10:05:00Z"
}
```

**生成スクリプト**: `tools/mc_context.py`

```python
#!/usr/bin/env python3
"""
mc_context — OMOS コンテキストファイル管理

セッション間でプロジェクトコンテキストを永続化し、LLM の記憶依存を排除する。
各コマンドは自動的にこのコンテキストを参照する。

Usage:
    mc_context init <project> --profile <profile> --mission <mission> --goal "<goal>" ...
    mc_context get <project> [--field <field>]
    mc_context set <project> --field <field> --value <value>
    mc_context step <project> <step_name>
    mc_context check <project> --require <step1>,<step2>,...
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

CONTEXT_DIR = Path("/tmp")


def context_path(project: str) -> Path:
    return CONTEXT_DIR / f"{project}-context.json"


def load_context(project: str) -> dict:
    p = context_path(project)
    if not p.exists():
        print(f"ERROR: No context found for project '{project}'.", file=sys.stderr)
        print(f"Run: mc_context init {project} --profile <profile> ...", file=sys.stderr)
        sys.exit(1)
    return json.loads(p.read_text())


def save_context(project: str, ctx: dict) -> None:
    ctx["updated_at"] = datetime.now(timezone.utc).isoformat()
    p = context_path(project)
    p.write_text(json.dumps(ctx, indent=2, ensure_ascii=False) + "\n")


def cmd_init(args):
    """Create a new context file for a project."""
    profile = args.profile or os.environ.get("OPENCLAW_PROFILE", "")
    if profile:
        config_dir = str(Path.home() / f".openclaw-{profile}")
    else:
        config_dir = str(Path.home() / ".openclaw")

    ctx = {
        "version": 1,
        "profile": profile,
        "config_dir": config_dir,
        "project": args.project,
        "mission": args.mission,
        "goal": args.goal,
        "slack_channel": args.slack_channel,
        "slack_user_id": args.slack_user_id,
        "roles": [r.strip() for r in args.roles.split(",") if r.strip()] if args.roles else [],
        "plan_path": args.plan_path,
        "roles_json_path": args.roles_json,
        "step_completed": {
            "profile_detection": datetime.now(timezone.utc).isoformat(),
            "mission_analysis": None,
            "team_design": None,
            "plan_created": None,
            "user_approved": None,
            "setup_executed": None,
            "brain_delegated": None,
            "completion_reported": None,
        },
        "created_at": datetime.now(timezone.utc).isoformat(),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }

    save_context(args.project, ctx)
    print(f"Context created: {context_path(args.project)}")
    print(json.dumps(ctx, indent=2, ensure_ascii=False))


def cmd_get(args):
    """Read context or a specific field."""
    ctx = load_context(args.project)
    if args.field:
        parts = args.field.split(".")
        val = ctx
        for p in parts:
            val = val.get(p) if isinstance(val, dict) else None
            if val is None:
                print(f"ERROR: Field '{args.field}' not found.", file=sys.stderr)
                sys.exit(1)
        print(val if isinstance(val, str) else json.dumps(val))
    else:
        print(json.dumps(ctx, indent=2, ensure_ascii=False))


def cmd_set(args):
    """Update a field in the context."""
    ctx = load_context(args.project)
    parts = args.field.split(".")
    target = ctx
    for p in parts[:-1]:
        target = target.setdefault(p, {})
    target[parts[-1]] = args.value
    save_context(args.project, ctx)
    print(f"Updated {args.field} = {args.value}")


def cmd_step(args):
    """Mark a step as completed."""
    ctx = load_context(args.project)
    step_name = args.step_name
    if step_name not in ctx.get("step_completed", {}):
        print(f"ERROR: Unknown step '{step_name}'. Valid steps: {list(ctx['step_completed'].keys())}", file=sys.stderr)
        sys.exit(1)
    ctx["step_completed"][step_name] = datetime.now(timezone.utc).isoformat()
    save_context(args.project, ctx)
    print(f"Step '{step_name}' marked as completed at {ctx['step_completed'][step_name]}")


def cmd_check(args):
    """Check that required steps are completed. Exit 1 if any are missing."""
    ctx = load_context(args.project)
    required = [s.strip() for s in args.require.split(",")]
    missing = []
    for step in required:
        if step not in ctx.get("step_completed", {}):
            missing.append(f"  {step}: unknown step")
        elif ctx["step_completed"].get(step) is None:
            missing.append(f"  {step}: NOT completed")

    if missing:
        print("PRECONDITION FAILED — the following steps have not been completed:", file=sys.stderr)
        for m in missing:
            print(m, file=sys.stderr)
        sys.exit(1)
    else:
        print(f"All preconditions met: {', '.join(required)}")


def main():
    parser = argparse.ArgumentParser(description="OMOS Context File Manager")
    sub = parser.add_subparsers(dest="command")

    p_init = sub.add_parser("init", help="Create context for a project")
    p_init.add_argument("project")
    p_init.add_argument("--profile")
    p_init.add_argument("--mission", required=True)
    p_init.add_argument("--goal", required=True)
    p_init.add_argument("--slack-channel")
    p_init.add_argument("--slack-user-id")
    p_init.add_argument("--roles")
    p_init.add_argument("--plan-path")
    p_init.add_argument("--roles-json")

    p_get = sub.add_parser("get", help="Read context")
    p_get.add_argument("project")
    p_get.add_argument("--field")

    p_set = sub.add_parser("set", help="Update context field")
    p_set.add_argument("project")
    p_set.add_argument("--field", required=True)
    p_set.add_argument("--value", required=True)

    p_step = sub.add_parser("step", help="Mark step as completed")
    p_step.add_argument("project")
    p_step.add_argument("step_name")

    p_check = sub.add_parser("check", help="Verify preconditions")
    p_check.add_argument("project")
    p_check.add_argument("--require", required=True)

    args = parser.parse_args()
    if args.command == "init":
        cmd_init(args)
    elif args.command == "get":
        cmd_get(args)
    elif args.command == "set":
        cmd_set(args)
    elif args.command == "step":
        cmd_step(args)
    elif args.command == "check":
        cmd_check(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
```

### なぜこうするのか

- **LLM 記憶依存の排除**: profile 値やプロジェクト情報がファイルに永続化されるため、セッション跨ぎでも確実に状態を復元できる
- **前提条件の検証が宣言的**: `mc_context check <project> --require profile_detection,plan_created,user_approved` の1コマンドで、setup_mission 実行前の全前提条件を検証できる
- **ステートマシンとの違い**: 状態遷移を強制するのではなく、「必要な前提が満たされているか」を検証するだけ。ステップの順序を変更しても、前提条件さえ満たされていれば問題ない

---

## 提案 2: ガードレール付きラッパー — `mc_safe_setup`

### 問題

仕様書の Step 4 は「承認後のみ setup_mission を実行」と記載しているが、これは自然言語の指示に過ぎない。LLM が承認なしに setup_mission を実行するリスクがある（実際の x-growth-v2 事故がこのパターン）。

### 解決策: `tools/mc_safe_setup.py`

setup_mission の呼び出しをラップし、前提条件を自動検証する。

```python
#!/usr/bin/env python3
"""
mc_safe_setup — setup_mission のガードレール付きラッパー

前提条件を自動検証してから setup_mission を実行する。
- コンテキストファイルの存在確認
- plan.md の存在とフォーマット検証
- ユーザー承認フラグの確認
- profile の整合性検証

Usage:
    mc_safe_setup <project>
    (全パラメータはコンテキストファイルから自動取得)
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def load_context(project: str) -> dict:
    ctx_path = Path(f"/tmp/{project}-context.json")
    if not ctx_path.exists():
        print(f"GUARD: Context file not found: {ctx_path}", file=sys.stderr)
        print(f"  Run: mc_context init {project} ...", file=sys.stderr)
        sys.exit(1)
    return json.loads(ctx_path.read_text())


def validate_plan(plan_path: str) -> list[str]:
    """Validate plan.md format. Returns list of errors."""
    errors = []
    p = Path(plan_path)
    if not p.exists():
        return [f"Plan file not found: {plan_path}"]
    if p.stat().st_size == 0:
        return [f"Plan file is empty: {plan_path}"]

    content = p.read_text()

    # 必須セクションの検証
    if not re.search(r"^#\s+Mission Plan:", content, re.MULTILINE):
        errors.append("Missing '# Mission Plan:' header")
    if not re.search(r"^##\s+Goal", content, re.MULTILINE):
        errors.append("Missing '## Goal' section")
    if not re.search(r"^##\s+Agents", content, re.MULTILINE):
        errors.append("Missing '## Agents' section")
    if not re.search(r"^##\s+Phase\s+1", content, re.MULTILINE):
        errors.append("Missing '## Phase 1' section")

    # Phase 1 に Auto: true が含まれているか
    phase1_match = re.search(
        r"^##\s+Phase\s+1.*?\n(.*?)(?=^##\s+Phase\s+2|\Z)",
        content, re.MULTILINE | re.DOTALL
    )
    if phase1_match:
        phase1_content = phase1_match.group(1)
        if "Auto: true" not in phase1_content:
            errors.append("Phase 1 must have 'Auto: true' for immediate task creation")

    # タスクが存在するか
    tasks = re.findall(r"^-\s+\[\s*\]", content, re.MULTILINE)
    if not tasks:
        errors.append("No tasks found (expected '- [ ] ...' format)")

    # @role が存在するか
    roles_in_plan = re.findall(r"@(\w[\w-]*)", content)
    if not roles_in_plan:
        errors.append("No role assignments found (expected '@role' format)")

    # Success Criteria が存在するか
    if not re.search(r"^###\s+Success Criteria", content, re.MULTILINE):
        errors.append("Missing '### Success Criteria' section")

    return errors


def main():
    if len(sys.argv) < 2:
        print("Usage: mc_safe_setup <project>", file=sys.stderr)
        sys.exit(1)

    project = sys.argv[1]
    ctx = load_context(project)

    print("=" * 60)
    print("GUARD: Pre-flight checks for setup_mission")
    print("=" * 60)

    errors = []

    # 1. Profile 検証
    profile = ctx.get("profile", "")
    env_profile = os.environ.get("OPENCLAW_PROFILE", "")
    if profile and profile != env_profile:
        errors.append(
            f"Profile mismatch: context says '{profile}', "
            f"but OPENCLAW_PROFILE='{env_profile}'"
        )
    print(f"  [{'OK' if not profile or profile == env_profile else 'FAIL'}] Profile: {profile or '(default)'}")

    # 2. 必須フィールド検証
    for field in ["project", "mission", "goal", "slack_channel", "slack_user_id"]:
        val = ctx.get(field)
        if not val:
            errors.append(f"Missing required field: {field}")
        print(f"  [{'OK' if val else 'FAIL'}] {field}: {val or '(missing)'}")

    # 3. Roles 検証
    roles = ctx.get("roles", [])
    if not roles:
        errors.append("No roles defined")
    print(f"  [{'OK' if roles else 'FAIL'}] Roles: {', '.join(roles) if roles else '(none)'}")

    # 4. Plan 検証
    plan_path = ctx.get("plan_path")
    if not plan_path:
        errors.append("No plan_path in context")
        print(f"  [FAIL] Plan: (not specified)")
    else:
        plan_errors = validate_plan(plan_path)
        if plan_errors:
            for e in plan_errors:
                errors.append(f"Plan validation: {e}")
            print(f"  [FAIL] Plan: {plan_path}")
            for e in plan_errors:
                print(f"         - {e}")
        else:
            print(f"  [OK] Plan: {plan_path}")

    # 5. ユーザー承認検証
    user_approved = ctx.get("step_completed", {}).get("user_approved")
    if not user_approved:
        errors.append("User has NOT approved the plan. Run: mc_context step <project> user_approved")
    print(f"  [{'OK' if user_approved else 'FAIL'}] User approval: {user_approved or 'NOT APPROVED'}")

    # 6. 前提ステップの検証
    required_steps = ["profile_detection", "mission_analysis", "team_design", "plan_created"]
    for step in required_steps:
        completed = ctx.get("step_completed", {}).get(step)
        if not completed:
            errors.append(f"Step '{step}' has not been completed")
        print(f"  [{'OK' if completed else 'FAIL'}] Step {step}: {completed or '(pending)'}")

    print()

    if errors:
        print(f"GUARD: BLOCKED — {len(errors)} error(s) found:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        print(f"\nsetup_mission was NOT executed.", file=sys.stderr)
        sys.exit(1)

    # 全チェック通過 — setup_mission を構築・実行
    print("GUARD: All checks passed. Executing setup_mission...")
    print()

    cmd_parts = [
        "setup_mission",
        ctx["project"],
        ctx["mission"],
        f'"{ctx["goal"]}"',
        f"--roles {','.join(ctx['roles'])}",
        f"--slack-channel {ctx['slack_channel']}",
        f"--slack-user-id {ctx['slack_user_id']}",
        f"--plan {ctx['plan_path']}",
    ]

    if ctx.get("profile"):
        cmd_parts.append(f"--profile {ctx['profile']}")

    if ctx.get("roles_json_path"):
        cmd_parts.append(f"--role-config {ctx['roles_json_path']}")

    cmd = " ".join(cmd_parts)
    print(f"  Command: {cmd}")
    print()

    result = subprocess.run(cmd, shell=True)

    if result.returncode == 0:
        # コンテキストにステップ完了を記録
        subprocess.run(
            f"mc_context step {project} setup_executed",
            shell=True, capture_output=True
        )
        print("\nGUARD: setup_mission completed successfully.")
    else:
        print(f"\nGUARD: setup_mission FAILED with exit code {result.returncode}.", file=sys.stderr)
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
```

### なぜこうするのか

- **承認なし実行の防止**: `user_approved` ステップが未完了なら、`mc_safe_setup` が setup_mission の実行をブロックする。LLM が「承認なしで実行しよう」と判断しても、プログラムレベルで阻止される
- **plan.md のフォーマット検証**: 必須セクション、タスクフォーマット、Phase 1 の `Auto: true`、Success Criteria の存在を自動検証。LLM が不完全な plan を作成しても、setup_mission 実行前にキャッチできる
- **冪等性**: 同じコマンドを何度実行しても安全。コンテキストファイルの内容が変わらなければ同じ setup_mission コマンドが生成される
- **ステートマシンとの違い**: 状態遷移を管理しているのではなく、「前提条件が満たされているか」を検証しているだけ。新しい前提条件（例: セキュリティレビュー必須）を追加する場合、`validate_plan` に1つのチェックを追加するだけでよい

---

## 提案 3: Cron ヘルパースクリプト — 複雑な bash ワンライナーの排除

### 問題

Agent B が定量分析したように、Cron Guard の bash ワンライナーは全テンプレートに13回コピーされ、セッションあたり約49%の確率で少なくとも1回失敗する。Agent B は `mc cron-guard` サブコマンドの追加を提案しているが、本提案ではより軽量な方法で同じ効果を得る。

### 解決策: `tools/omos_cron_helper.sh`

独立したヘルパースクリプトとして提供し、mc CLI の改修を不要にする。

```bash
#!/usr/bin/env bash
# omos_cron_helper — Cron Guard operations for OMOS agents
#
# Usage:
#   omos_cron_helper disable <agent-name>
#   omos_cron_helper enable <agent-name>
#   omos_cron_helper status <agent-name>
#
# Always exits 0 (best-effort). Failures are logged but do not block the caller.
set -uo pipefail

ACTION="${1:-}"
AGENT_NAME="${2:-}"

if [[ -z "$ACTION" || -z "$AGENT_NAME" ]]; then
    echo "Usage: omos_cron_helper <disable|enable|status> <agent-name>" >&2
    exit 0  # Best-effort: never block the caller
fi

PROFILE_FLAG=""
if [[ -n "${OPENCLAW_PROFILE:-}" ]]; then
    PROFILE_FLAG="--profile $OPENCLAW_PROFILE"
fi

# Resolve cron ID from agent name
resolve_cron_id() {
    local agent="$1"
    local json_output
    json_output=$(openclaw $PROFILE_FLAG cron list --json 2>/dev/null) || return 1

    # Use python3 for reliable JSON parsing
    echo "$json_output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for job in data.get('jobs', []):
        if job.get('name') == '$agent':
            print(job['id'])
            break
except Exception:
    pass
" 2>/dev/null
}

case "$ACTION" in
    disable)
        cron_id=$(resolve_cron_id "$AGENT_NAME")
        if [[ -n "$cron_id" ]]; then
            openclaw $PROFILE_FLAG cron disable "$cron_id" 2>/dev/null \
                && echo "[CRON_GUARD] $AGENT_NAME: cron disabled at $(date '+%Y-%m-%d %H:%M:%S')" \
                || echo "[CRON_GUARD] $AGENT_NAME: disable failed (best-effort, continuing)" >&2
        else
            echo "[CRON_GUARD] $AGENT_NAME: cron_id not found (best-effort, continuing)" >&2
        fi
        ;;
    enable)
        cron_id=$(resolve_cron_id "$AGENT_NAME")
        if [[ -n "$cron_id" ]]; then
            openclaw $PROFILE_FLAG cron enable "$cron_id" 2>/dev/null \
                && echo "[CRON_GUARD] $AGENT_NAME: cron enabled at $(date '+%Y-%m-%d %H:%M:%S')" \
                || echo "[CRON_GUARD] $AGENT_NAME: enable failed (best-effort, continuing)" >&2
        else
            echo "[CRON_GUARD] $AGENT_NAME: cron_id not found (best-effort, continuing)" >&2
        fi
        ;;
    status)
        cron_id=$(resolve_cron_id "$AGENT_NAME")
        if [[ -n "$cron_id" ]]; then
            echo "[CRON_GUARD] $AGENT_NAME: cron_id=$cron_id"
        else
            echo "[CRON_GUARD] $AGENT_NAME: cron not found"
        fi
        ;;
    *)
        echo "Unknown action: $ACTION (expected disable|enable|status)" >&2
        ;;
esac

exit 0  # Always exit 0 — best-effort principle
```

### テンプレートへの影響

**変更前** (brain.md Step 0 — 3行, 複雑):
```bash
cron_id=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") && openclaw --profile "$OPENCLAW_PROFILE" cron disable "$cron_id" && echo "[CRON_GUARD] {agent_id}: cron disabled at $(date '+%Y-%m-%d %H:%M:%S') — session started"
```

**変更後** (1行, 単純):
```bash
omos_cron_helper disable {agent_id}
```

全テンプレート（base.md, brain.md, monitor.md, escalator.md）の13箇所が1行コマンドに置換される。

### なぜ mc CLI のサブコマンドではなくヘルパースクリプトか

1. **mc CLI の改修が不要**: mc CLI は SQLite ベースのタスク管理ツールであり、openclaw の cron 管理は責務の範囲外。ヘルパースクリプトとして分離することで、関心の分離を維持
2. **独立してテスト可能**: `omos_cron_helper status <agent>` でデバッグ可能
3. **インストールが容易**: `install.sh` に1行追加するだけ (`cp "$SCRIPT_DIR/tools/omos_cron_helper.sh" "$BIN_DIR/omos_cron_helper"`)
4. **mc CLI を改修するアプローチ（Agent B 提案1）との互換性**: 将来的に `mc cron-guard` に統合する場合でも、ヘルパースクリプトをラッパーとして残せばテンプレートの変更は不要

---

## 提案 4: plan.md のスキーマバリデーション

### 問題

plan.md は mc-architect が生成し、brain が解釈する OMOS の「設計図」であるにもかかわらず、フォーマットの検証が全く行われていない。Agent C は YAML フロントマターの導入を提案しているが、Agent A が指摘するように「LLM に YAML を正確に書かせる」前提に矛盾がある。

### 解決策: 独立したバリデーションスクリプト

plan.md の Markdown フォーマットをそのまま検証する。YAML フロントマターのような二重管理は行わない。

**バリデーション（`mc_safe_setup.py` 内の `validate_plan` 関数として既に統合済み）に加えて、スタンドアロンのバリデーションコマンドも提供する:**

```python
#!/usr/bin/env python3
"""
mc_validate_plan — plan.md のスキーマバリデーション

Usage:
    mc_validate_plan <plan.md> [--roles role1,role2,...] [--strict]
"""

import argparse
import json
import re
import sys
from pathlib import Path


def validate_plan(plan_path: str, roles: list[str] | None = None, strict: bool = False) -> tuple[list[str], list[str]]:
    """
    Validate plan.md format.
    Returns (errors, warnings).
    errors = must fix before proceeding
    warnings = should review but not blocking
    """
    errors = []
    warnings = []
    p = Path(plan_path)

    if not p.exists():
        return [f"File not found: {plan_path}"], []
    if p.stat().st_size == 0:
        return [f"File is empty: {plan_path}"], []

    content = p.read_text()
    lines = content.splitlines()

    # --- Header ---
    if not re.search(r"^#\s+Mission Plan:", content, re.MULTILINE):
        errors.append("Missing '# Mission Plan:' header")

    # --- Goal ---
    goal_match = re.search(r"^##\s+Goal\s*$", content, re.MULTILINE)
    if not goal_match:
        errors.append("Missing '## Goal' section")
    else:
        # Goal の次の行が空でないか
        goal_line = content.index("## Goal")
        remaining = content[goal_line:].split("\n")
        if len(remaining) < 2 or not remaining[1].strip():
            warnings.append("'## Goal' section appears to be empty")

    # --- Agents ---
    if not re.search(r"^##\s+Agents\s*$", content, re.MULTILINE):
        errors.append("Missing '## Agents' section")

    # --- Phases ---
    phases = re.findall(r"^##\s+Phase\s+(\d+):\s*(.+)$", content, re.MULTILINE)
    if not phases:
        errors.append("No phases found (expected '## Phase N: <name>')")
    else:
        # Phase 番号の連続性チェック
        phase_nums = [int(p[0]) for p in phases]
        expected = list(range(1, max(phase_nums) + 1))
        if phase_nums != expected:
            warnings.append(f"Phase numbers are not sequential: {phase_nums} (expected {expected})")

    # --- Phase 1: Auto: true ---
    phase1_section = re.search(
        r"^##\s+Phase\s+1.*?\n(.*?)(?=^##\s+Phase\s+2|\Z)",
        content, re.MULTILINE | re.DOTALL
    )
    if phase1_section:
        if "Auto: true" not in phase1_section.group(1):
            errors.append("Phase 1 must have 'Auto: true' for immediate task creation")

    # --- Tasks ---
    tasks = re.findall(r"^-\s+\[\s*\]\s+(.+)$", content, re.MULTILINE)
    if not tasks:
        errors.append("No tasks found (expected '- [ ] ...' format)")

    # タスク内の @role 検証
    roles_in_plan = set()
    for task in tasks:
        role_matches = re.findall(r"@([\w-]+)", task)
        if not role_matches:
            warnings.append(f"Task has no role assignment: '{task[:60]}...'")
        roles_in_plan.update(role_matches)

    # 提供された roles との照合
    if roles:
        unknown_roles = roles_in_plan - set(roles)
        if unknown_roles:
            errors.append(f"Tasks reference unknown roles: {unknown_roles} (known: {roles})")
        unused_roles = set(roles) - roles_in_plan
        if unused_roles:
            warnings.append(f"Roles defined but not used in any task: {unused_roles}")

    # --- Priority ---
    priorities = re.findall(r"\[P(\d+)\]", content)
    for p in priorities:
        if int(p) not in (0, 1, 2):
            errors.append(f"Invalid priority [P{p}] (must be 0, 1, or 2)")

    # --- Success Criteria ---
    criteria_count = len(re.findall(r"^###\s+Success Criteria", content, re.MULTILINE))
    if criteria_count == 0:
        errors.append("No '### Success Criteria' sections found")
    elif criteria_count < len(phases):
        warnings.append(f"Only {criteria_count} Success Criteria sections for {len(phases)} phases")

    # --- Strict mode additional checks ---
    if strict:
        # 各タスクに priority が指定されているか
        for task in tasks:
            if not re.search(r"\[P[012]\]", task):
                warnings.append(f"Task missing priority: '{task[:60]}...'")

        # 各 Phase に Timeline が指定されているか
        for num, name in phases:
            phase_section = re.search(
                rf"^##\s+Phase\s+{num}.*?\n(.*?)(?=^##\s+Phase\s+{int(num)+1}|\Z)",
                content, re.MULTILINE | re.DOTALL
            )
            if phase_section and "Timeline:" not in phase_section.group(1):
                warnings.append(f"Phase {num} missing 'Timeline:' field")

    return errors, warnings


def main():
    parser = argparse.ArgumentParser(description="Validate plan.md format")
    parser.add_argument("plan", help="Path to plan.md")
    parser.add_argument("--roles", help="Comma-separated list of expected roles")
    parser.add_argument("--strict", action="store_true", help="Enable strict validation")
    parser.add_argument("--json", action="store_true", help="Output as JSON")

    args = parser.parse_args()
    roles = [r.strip() for r in args.roles.split(",") if r.strip()] if args.roles else None

    errors, warnings = validate_plan(args.plan, roles, args.strict)

    if args.json:
        result = {"errors": errors, "warnings": warnings, "valid": len(errors) == 0}
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        if errors:
            print(f"ERRORS ({len(errors)}):")
            for e in errors:
                print(f"  - {e}")
        if warnings:
            print(f"WARNINGS ({len(warnings)}):")
            for w in warnings:
                print(f"  - {w}")
        if not errors:
            print("VALID: plan.md passes all checks")

    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
```

### なぜ YAML フロントマターではなくスキーマバリデーションか

1. **二重管理の排除**: YAML フロントマター（Agent C 提案2）は Markdown 本文との二重管理を生む。スキーマバリデーションは既存の Markdown フォーマットをそのまま検証するため、情報源は1つだけ
2. **LLM の認知負荷を増やさない**: architect が plan.md を生成する際のフォーマットは現在と同じ。YAML の正確な構文を生成する追加負荷がない
3. **段階的な厳格化が可能**: `--strict` フラグで検証レベルを調整できる。最初は緩い検証から始め、運用経験に基づいて徐々に厳格化する
4. **Agent B の Phase 管理 CLI 化との親和性**: 将来的に `mc phase create-tasks` が plan.md をパースする際、このバリデーションを内部で再利用できる

---

## 提案 5: テンプレート変数の安全な展開 — Jinja2 導入

### 問題

現在の `setup_mission.py` は `str.replace()` でテンプレート変数を展開している（L62-67 の `safe_render` 関数）。これは以下の問題がある:

- `{project}` が `specialization` テキスト内に含まれる場合、展開順序によっては二重展開される（L148-159 でこの問題に対処しているが脆弱）
- テンプレート内に `{` と `}` がリテラルとして必要な場合（bash の `${VAR}` 等）、エスケープ機構がない
- 条件分岐（テンプレート内で値の有無による出力の切り替え）ができない

### 解決策: Python の `string.Template` を使った安全な展開

Jinja2 のような外部依存は追加せず、Python 標準ライブラリの `string.Template` で置き換える。`$` プレフィックスを使うことで `{` `}` との衝突を回避する。

```python
# setup_mission.py の safe_render を置き換え

from string import Template

def safe_render(template: str, **kwargs: str) -> str:
    """Render template using Python's string.Template for safe variable expansion.

    Uses $variable or ${variable} syntax instead of {variable}.
    Literal $ signs must be escaped as $$.
    Unknown variables are left unchanged.
    """
    # まず旧式の {var} を ${var} に変換（後方互換性）
    for key in kwargs:
        template = template.replace(f"{{{key}}}", f"${{{key}}}")

    class SafeTemplate(Template):
        """Template subclass that leaves unknown variables unchanged."""
        pass

    try:
        return SafeTemplate(template).safe_substitute(**kwargs)
    except (KeyError, ValueError):
        # Fallback to str.replace for robustness
        result = template
        for key, value in kwargs.items():
            result = result.replace(f"${{{key}}}", value)
        return result
```

### なぜこうするのか

しかし実際には、現在の `safe_render` は十分にシンプルで実用的に動作している。この提案は「将来的に問題が発生した場合の改善パス」として位置づける。**即時の優先度は低い。**

代わりに、より緊急性の高い改善として、テンプレート内の bash コードブロック（Cron Guard 等）をヘルパースクリプト化する（提案3）ことで、テンプレート変数の展開が関与する複雑な bash を減らすアプローチを推奨する。

---

## 提案 6: 防御的自己診断 — エージェント起動時の環境検証

### 問題

各エージェントは起動時に AGENTS.md のワークフローを実行するが、環境が正しく構成されているかの検証がない。例えば:
- `mc` コマンドが PATH にない
- `OPENCLAW_PROFILE` が設定されていない
- ワーキングディレクトリが存在しない
- `omos_cron_helper` がインストールされていない

### 解決策: `tools/omos_self_check.sh`

各テンプレートの Step 0 の直前に実行する、最小限の環境検証スクリプト。

```bash
#!/usr/bin/env bash
# omos_self_check — エージェント起動時の環境検証
#
# Usage:
#   omos_self_check <agent-id> <project> <mission> <config-dir>
#
# Exits 0 if environment is valid, 1 if critical issues found.
# Non-critical warnings are printed but don't cause failure.

AGENT_ID="${1:-}"
PROJECT="${2:-}"
MISSION="${3:-}"
CONFIG_DIR="${4:-}"

if [[ -z "$AGENT_ID" || -z "$PROJECT" || -z "$MISSION" || -z "$CONFIG_DIR" ]]; then
    echo "[SELF_CHECK] ERROR: Missing arguments" >&2
    echo "Usage: omos_self_check <agent-id> <project> <mission> <config-dir>" >&2
    exit 1
fi

ERRORS=0
WARNINGS=0

check_ok() { echo "[SELF_CHECK] OK: $1"; }
check_warn() { echo "[SELF_CHECK] WARN: $1"; ((WARNINGS++)); }
check_fail() { echo "[SELF_CHECK] FAIL: $1" >&2; ((ERRORS++)); }

# 1. 必須コマンドの存在確認
for cmd in mc python3 openclaw; do
    if command -v "$cmd" >/dev/null 2>&1; then
        check_ok "$cmd found"
    else
        check_fail "$cmd not found in PATH"
    fi
done

# 2. omos_cron_helper の存在確認
if command -v omos_cron_helper >/dev/null 2>&1; then
    check_ok "omos_cron_helper found"
else
    check_warn "omos_cron_helper not found — cron guard will use fallback"
fi

# 3. OPENCLAW_PROFILE の確認
if [[ -n "${OPENCLAW_PROFILE:-}" ]]; then
    check_ok "OPENCLAW_PROFILE=$OPENCLAW_PROFILE"
else
    check_warn "OPENCLAW_PROFILE is not set (using default profile)"
fi

# 4. Config ディレクトリの存在確認
if [[ -d "$CONFIG_DIR" ]]; then
    check_ok "Config dir exists: $CONFIG_DIR"
else
    check_fail "Config dir not found: $CONFIG_DIR"
fi

# 5. Project ディレクトリの存在確認
PROJECT_DIR="$CONFIG_DIR/projects/$PROJECT"
if [[ -d "$PROJECT_DIR" ]]; then
    check_ok "Project dir exists: $PROJECT_DIR"
else
    check_warn "Project dir not found: $PROJECT_DIR (will be created if needed)"
fi

# 6. MC プロジェクトの確認
if mc -p "$PROJECT" -m "$MISSION" mission status >/dev/null 2>&1; then
    check_ok "Mission '$PROJECT/$MISSION' is accessible"
else
    check_fail "Cannot access mission '$PROJECT/$MISSION'"
fi

echo
if [[ $ERRORS -gt 0 ]]; then
    echo "[SELF_CHECK] $AGENT_ID: $ERRORS error(s), $WARNINGS warning(s) — ENVIRONMENT INVALID"
    exit 1
else
    echo "[SELF_CHECK] $AGENT_ID: 0 errors, $WARNINGS warning(s) — environment OK"
    exit 0
fi
```

### テンプレートへの統合

base.md, brain.md, monitor.md, escalator.md のワークフロー冒頭に追加:

```markdown
### -1. Self Check (Environment Verification)
```bash
omos_self_check {agent_id} {project} {mission} {config_dir}
```
If this fails, stop and report the error. Do not proceed with the workflow.
```

### なぜこうするのか

- **静かな環境破壊の防止**: `mc` コマンドが壊れていたり、プロジェクトディレクトリが消えていたりする場合、ワークフロー途中で意味不明なエラーになるよりも、起動時に明確なエラーメッセージで停止する方がデバッグが容易
- **テンプレートへの追加は1行のみ**: 認知負荷の増加は最小限
- **ベストエフォート**: `omos_cron_helper` が未インストールの場合は警告だけで続行する（フォールバックとして旧式のワンライナーが使える）

---

## ファイル構成

```
mission-control/
  tools/
    setup_mission.py       # 既存（冪等性改善を適用）
    mc_context.py          # 新規: コンテキストファイル管理
    mc_safe_setup.py       # 新規: ガードレール付き setup_mission ラッパー
    mc_validate_plan.py    # 新規: plan.md スキーマバリデーション
    omos_cron_helper.sh    # 新規: Cron Guard ヘルパー
    omos_self_check.sh     # 新規: 環境自己診断
  agents/
    templates/
      base.md              # 修正: cron_helper 使用 + self_check + in_progress 再開
      brain.md             # 修正: cron_helper 使用 + self_check
      monitor.md           # 修正: cron_helper 使用 + self_check
      escalator.md         # 修正: cron_helper 使用 + self_check
    architect/
      AGENTS.md            # 修正: mc_context + mc_safe_setup を使用するフロー
  install.sh               # 修正: 新規ツールのインストール追加
```

---

## 実装優先度

### Tier 1: 即座に実施（工数小、効果大、リスク低）

| # | 施策 | 工数 | 理由 |
|---|------|------|------|
| 1 | **omos_cron_helper.sh** | 30分 | 13箇所の bash ワンライナーを1行コマンドに置換。全テンプレートの信頼性が即座に向上。Agent B 提案1と同じ方向だが mc CLI 改修不要 |
| 2 | **in_progress タスクの優先再開** | 15分 | base.md に3行追加。Agent A 提案1。最小コストで最大の効果 |
| 3 | **setup_mission の冪等性** | 1時間 | Agent A 提案3。Python コードの修正で確実に動作。部分障害からの安全なリトライ |

### Tier 2: 次のイテレーション（工数中、効果大）

| # | 施策 | 工数 | 理由 |
|---|------|------|------|
| 4 | **mc_context.py** | 2時間 | LLM 記憶依存の排除。セッション跨ぎの状態管理を確実にする |
| 5 | **mc_safe_setup.py + mc_validate_plan.py** | 2時間 | 承認なし実行の防止 + plan.md フォーマット検証。x-growth-v2 事故の再発防止 |
| 6 | **omos_self_check.sh** | 30分 | 環境破壊の早期検出。テンプレートへの変更は1行のみ |

### Tier 3: 中期（工数大、基盤整備）

| # | 施策 | 工数 | 理由 |
|---|------|------|------|
| 7 | **mc-architect AGENTS.md の改修** | 3時間 | コンテキストファイル方式を使ったフロー全体の書き直し。Step の再番号付け（Agent B 提案4）も同時実施 |
| 8 | **install.sh の更新** | 30分 | 新規ツールのインストール追加 |

---

## 他のエージェント提案との関係

### Agent A（耐障害性）との関係

| Agent A 提案 | 本提案の対応 | 判断 |
|-------------|------------|------|
| 提案1: in_progress 再開 | **全面採用** | 最小変更で最大効果。base.md に3行追加 |
| 提案2: plan.md 安全書き込み | **部分採用**: バックアップ作成は採用。tmp+validate+mv の複雑なワンライナーは omos_cron_helper と同じ理由で簡素化 |
| 提案3: setup_mission 冪等化 | **全面採用** | Python コード改修で確実に動作 |
| 提案4: brain-monitor 相互監視 | **棚上げ**: omos_cron_helper によって Cron Guard 失敗率自体が大幅に低下するため、相互監視の緊急度は下がる |
| 提案5: LLM ガードレール | **mc_safe_setup で代替**: 自然言語の指示ではなく、プログラムレベルでの制限 |
| 提案7: ファイルロック | **不採用**: Agent B の批判に同意。新たな障害点になる |
| 提案8: セッション状態ファイル | **不採用**: mc CLI のタスク状態が Single Source of Truth |

### Agent B（シンプリシティ）との関係

| Agent B 提案 | 本提案の対応 | 判断 |
|-------------|------------|------|
| 提案1: Cron Guard CLI 化 | **omos_cron_helper.sh で代替**: 同じ効果を mc CLI 改修なしで実現 |
| 提案2: Supervisor 統合 | **棚上げ**: 方向性には賛同するが、Phase 管理 CLI 化（提案3）が先。Agent C の「観察者と行為者の同一化」批判にも一理ある |
| 提案3: Phase 管理 CLI 化 | **将来的に採用**: 本提案の mc_validate_plan.py が前段階。plan.md のパーサーが安定したら mc CLI に統合 |
| 提案4: Step 再番号付け | **採用**: Tier 3 で mc-architect AGENTS.md 改修時に同時実施 |
| 提案5: テンプレート DRY 化 | **omos_cron_helper + omos_self_check で部分実現**: 共通部分がヘルパースクリプトに外出しされる |
| 提案6: cron メッセージ最小化 | **採用**: setup_mission.py の即時修正 |

### Agent C（可観測性）との関係

| Agent C 提案 | 本提案の対応 | 判断 |
|-------------|------------|------|
| 提案1: Decision Log | **mc_context の step_completed が軽量版を提供**: 本格的な Decision Log は mc CLI レベルでの自動記録（Agent B 統合案）が正しいアプローチ |
| 提案2: YAML フロントマター | **mc_validate_plan.py で代替**: 二重管理を避けつつ、plan.md の構造的保証を提供 |
| 提案3: Phase 状態マシン | **棚上げ**: Agent B の Phase 管理 CLI 化の方が本質的 |
| 提案4: Plan Drift 検知 | **mc_validate_plan.py が前段階**: バリデーションで drift が起きにくくする「予防」アプローチ |
| 提案5c: 指示解釈確認 | **将来的に検討**: mc CLI レベルの自動ログが実装されてから |
| 提案6: タスク作成検証 | **将来的に mc CLI の `mc phase create-tasks` に統合**: 検証はプログラムコードで行うべき |

---

## 設計原則のまとめ

本提案の設計は以下の5つの原則に基づく:

1. **既存フローを壊さない**: mc-architect の Step 0-6、全テンプレートのワークフローは維持。ガードレールとしてラッパーやヘルパーを追加
2. **LLM に複雑な操作をさせない**: bash ワンライナーはヘルパースクリプトに、前提条件検証はラッパースクリプトに移す
3. **状態は外部ファイルに永続化する**: LLM の記憶に頼らず、コンテキストファイルで状態を管理
4. **新しいステップの追加が容易**: ガードレール関数の追加は既存コードに影響しない。イベント駆動的な拡張性
5. **段階的に導入できる**: Tier 1（30分-1時間の変更）から始めて、効果を確認しながら Tier 2, 3 に進む
