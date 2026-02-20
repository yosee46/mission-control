# Tier 1 実装テスト計画

> 対象仕様: `docs/debate/final-consensus-spec.md` Section 5.1 (Tier 1: 即時実施)
> 作成日: 2026-02-20

---

## 1. 構文テスト

### T-001: mc CLI bash 構文チェック
- **テスト名**: mc スクリプトが bash 構文エラーを含まないこと
- **テスト方法**:
  ```bash
  bash -n /Users/ogawa/workspace/mission-control/mc
  ```
- **期待結果**: 終了コード 0、エラー出力なし
- **合格基準**: `echo $?` が `0` であること

### T-002: setup_mission.py Python 構文チェック
- **テスト名**: setup_mission.py が Python 構文エラーを含まないこと
- **テスト方法**:
  ```bash
  python3 -m py_compile /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: 終了コード 0、エラー出力なし
- **合格基準**: `echo $?` が `0` であること

### T-003: テンプレートファイルが有効な UTF-8 であること
- **テスト名**: 全テンプレートファイルの文字エンコーディング
- **テスト方法**:
  ```bash
  for f in agents/templates/base.md agents/templates/brain.md agents/templates/monitor.md agents/templates/escalator.md; do
    file "$f" | grep -q "UTF-8\|ASCII" && echo "OK: $f" || echo "FAIL: $f"
  done
  ```
- **期待結果**: 全ファイルが OK
- **合格基準**: FAIL が 0 件

---

## 2. 存在テスト — mc cron-guard コマンド

### T-010: cmd_cron_guard 関数が mc に存在すること
- **テスト名**: cron-guard コマンドハンドラの存在
- **テスト方法**:
  ```bash
  grep -c '^cmd_cron_guard()' /Users/ogawa/workspace/mission-control/mc
  ```
- **期待結果**: `1`
- **合格基準**: 出力が `1`

### T-011: cron-guard が dispatch テーブルに登録されていること
- **テスト名**: dispatch テーブルへの cron-guard 登録
- **テスト方法**:
  ```bash
  grep 'cron-guard)' /Users/ogawa/workspace/mission-control/mc | grep 'cmd_cron_guard'
  ```
- **期待結果**: `cron-guard) shift; cmd_cron_guard "$@" ;;` に相当する行が見つかる
- **合格基準**: grep が終了コード 0

### T-012: cron-guard が DB 不要コマンドリストに含まれていること
- **テスト名**: cron-guard の DB 不要コマンド登録
- **テスト方法**:
  ```bash
  grep 'init|help.*cron-guard' /Users/ogawa/workspace/mission-control/mc
  ```
- **期待結果**: `cron-guard` が DB 不要コマンドの case パターンに含まれる
- **合格基準**: grep が終了コード 0

### T-013: cron-guard が help テキストに含まれていること
- **テスト名**: help 表示に cron-guard が記載されている
- **テスト方法**:
  ```bash
  grep -c 'cron-guard' /Users/ogawa/workspace/mission-control/mc | head -1
  ```
  更に help セクション内で3サブコマンド (disable/enable/check) が記載されていること:
  ```bash
  grep 'cron-guard disable' /Users/ogawa/workspace/mission-control/mc
  grep 'cron-guard enable' /Users/ogawa/workspace/mission-control/mc
  grep 'cron-guard check' /Users/ogawa/workspace/mission-control/mc
  ```
- **期待結果**: 3つの grep 全てがマッチ
- **合格基準**: 3サブコマンド全てが help テキスト内に記載

### T-014: cron-guard のベストエフォート実装（cron 未発見時に return 0）
- **テスト名**: cron job が見つからない場合に非致命的
- **テスト方法**:
  ```bash
  grep -A2 'No cron job found' /Users/ogawa/workspace/mission-control/mc | grep 'return 0'
  ```
- **期待結果**: `return 0` が存在する（エラー終了しない）
- **合格基準**: grep が終了コード 0

### T-015: cron-guard disable/enable がベストエフォートであること
- **テスト名**: disable/enable 失敗時も非致命的
- **テスト方法**:
  ```bash
  # disable の場合: 失敗しても stderr 出力のみで終了しないこと
  grep -A2 'disable)' /Users/ogawa/workspace/mission-control/mc | grep -E 'best-effort|stderr'
  # enable の場合
  grep -A2 'enable)' /Users/ogawa/workspace/mission-control/mc | grep -E 'best-effort|stderr'
  ```
- **期待結果**: 両方の case でベストエフォートの振る舞い（`|| echo ...` パターン等）が確認できる
- **合格基準**: disable/enable 両方のブランチで非致命的エラーハンドリングが存在

---

## 3. 存在テスト — テンプレート Cron Guard 置換

### T-020: base.md に `mc cron-guard disable` が存在すること
- **テスト名**: base.md の Cron Guard disable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard disable' /Users/ogawa/workspace/mission-control/agents/templates/base.md
  ```
- **期待結果**: `1` 以上
- **合格基準**: 出力が 1 以上

### T-021: base.md に `mc cron-guard enable` が存在すること
- **テスト名**: base.md の Cron Guard enable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard enable' /Users/ogawa/workspace/mission-control/agents/templates/base.md
  ```
- **期待結果**: `1` 以上（Step 1 の mission not active 時 + Step 8 の re-enable）
- **合格基準**: 出力が 1 以上

### T-022: brain.md に `mc cron-guard disable` が存在すること
- **テスト名**: brain.md の Cron Guard disable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard disable' /Users/ogawa/workspace/mission-control/agents/templates/brain.md
  ```
- **期待結果**: `1` 以上
- **合格基準**: 出力が 1 以上

### T-023: brain.md に `mc cron-guard enable` が存在すること
- **テスト名**: brain.md の Cron Guard enable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard enable' /Users/ogawa/workspace/mission-control/agents/templates/brain.md
  ```
- **期待結果**: `2` 以上（Step 1 mission not active + Step 7 re-enable + Section 6 target agent enable）
- **合格基準**: 出力が 2 以上

### T-024: brain.md にターゲットエージェント cron enable が `mc cron-guard enable` で記述されていること
- **テスト名**: brain.md Section 6 のターゲットエージェント cron enable 置換
- **テスト方法**:
  ```bash
  grep 'mc cron-guard enable' /Users/ogawa/workspace/mission-control/agents/templates/brain.md | grep -v '{agent_id}'
  ```
- **期待結果**: ターゲットエージェント向けの `mc cron-guard enable <agent-id>` パターンが見つかる
- **合格基準**: grep が終了コード 0

### T-025: monitor.md に `mc cron-guard disable` が存在すること
- **テスト名**: monitor.md の Cron Guard disable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard disable' /Users/ogawa/workspace/mission-control/agents/templates/monitor.md
  ```
- **期待結果**: `1` 以上
- **合格基準**: 出力が 1 以上

### T-026: monitor.md に `mc cron-guard enable` が存在すること
- **テスト名**: monitor.md の Cron Guard enable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard enable' /Users/ogawa/workspace/mission-control/agents/templates/monitor.md
  ```
- **期待結果**: `2` 以上（Step 1 mission not active + Step 5d stale agent recovery + Step 6 re-enable）
- **合格基準**: 出力が 2 以上

### T-027: escalator.md に `mc cron-guard disable` が存在すること
- **テスト名**: escalator.md の Cron Guard disable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard disable' /Users/ogawa/workspace/mission-control/agents/templates/escalator.md
  ```
- **期待結果**: `1` 以上
- **合格基準**: 出力が 1 以上

### T-028: escalator.md に `mc cron-guard enable` が存在すること
- **テスト名**: escalator.md の Cron Guard enable 置換
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard enable' /Users/ogawa/workspace/mission-control/agents/templates/escalator.md
  ```
- **期待結果**: `1` 以上（Step 1 mission not active + Step 5 re-enable）
- **合格基準**: 出力が 1 以上

---

## 4. 非存在テスト — 旧ワンライナー除去

### T-030: base.md から旧 cron ワンライナーが完全除去されていること
- **テスト名**: base.md 旧パターン除去
- **テスト方法**:
  ```bash
  grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/base.md
  ```
- **期待結果**: `0`
- **合格基準**: 出力が `0`

### T-031: brain.md から旧 cron ワンライナーが完全除去されていること
- **テスト名**: brain.md 旧パターン除去
- **テスト方法**:
  ```bash
  grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/brain.md
  ```
- **期待結果**: `0`
- **合格基準**: 出力が `0`

### T-032: monitor.md から旧 cron ワンライナーが完全除去されていること
- **テスト名**: monitor.md 旧パターン除去
- **テスト方法**:
  ```bash
  grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/monitor.md
  ```
- **期待結果**: `0`
- **合格基準**: 出力が `0`

### T-033: escalator.md から旧 cron ワンライナーが完全除去されていること
- **テスト名**: escalator.md 旧パターン除去
- **テスト方法**:
  ```bash
  grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/escalator.md
  ```
- **期待結果**: `0`
- **合格基準**: 出力が `0`

### T-034: 全テンプレートにおいて `cron_id=$( ` パターンが存在しないこと
- **テスト名**: 全テンプレート cron_id 変数パターン除去
- **テスト方法**:
  ```bash
  grep -r 'cron_id=\$(' /Users/ogawa/workspace/mission-control/agents/templates/
  ```
- **期待結果**: マッチなし（終了コード 1）
- **合格基準**: grep がマッチゼロ

### T-035: setup_mission.py のフォールバックテンプレートから旧ワンライナーが除去されていること
- **テスト名**: setup_mission.py フォールバックテンプレート旧パターン除去
- **テスト方法**:
  ```bash
  grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: `0`
- **合格基準**: 出力が `0`

### T-036: setup_mission.py のフォールバックテンプレートに `mc cron-guard` が使用されていること
- **テスト名**: setup_mission.py フォールバックテンプレート新パターン存在
- **テスト方法**:
  ```bash
  grep -c 'mc cron-guard' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: `4` 以上（4つのフォールバックテンプレート: base, monitor, brain, escalator にそれぞれ少なくとも1つ）
- **合格基準**: 出力が 4 以上

---

## 5. 存在テスト — base.md in_progress 再開ロジック

### T-040: base.md Step 3 が "Resume or Find Work" に変更されていること
- **テスト名**: Step 3 タイトル変更
- **テスト方法**:
  ```bash
  grep 'Resume or Find Work' /Users/ogawa/workspace/mission-control/agents/templates/base.md
  ```
- **期待結果**: マッチあり
- **合格基準**: grep が終了コード 0

### T-041: base.md に in_progress タスク確認が存在すること
- **テスト名**: in_progress ステータスの確認コマンド
- **テスト方法**:
  ```bash
  grep 'list --mine --status in_progress' /Users/ogawa/workspace/mission-control/agents/templates/base.md
  ```
- **期待結果**: マッチあり
- **合格基準**: grep が終了コード 0

### T-042: in_progress 確認が pending 確認より先に記述されていること
- **テスト名**: in_progress が pending より先
- **テスト方法**:
  ```bash
  # in_progress の行番号を取得
  ip_line=$(grep -n 'status in_progress' /Users/ogawa/workspace/mission-control/agents/templates/base.md | head -1 | cut -d: -f1)
  # pending の行番号を取得
  pend_line=$(grep -n 'status pending' /Users/ogawa/workspace/mission-control/agents/templates/base.md | head -1 | cut -d: -f1)
  # in_progress が先であること
  if [ "$ip_line" -lt "$pend_line" ]; then echo "PASS"; else echo "FAIL: in_progress at line $ip_line, pending at line $pend_line"; fi
  ```
- **期待結果**: `PASS`
- **合格基準**: in_progress の行番号 < pending の行番号

### T-043: 再開手順の記述が存在すること
- **テスト名**: in_progress タスクの再開手順
- **テスト方法**:
  ```bash
  grep -i 'resume' /Users/ogawa/workspace/mission-control/agents/templates/base.md | grep -i 'in.progress\|left off\|continue'
  ```
- **期待結果**: 再開に関する説明テキストが見つかる
- **合格基準**: grep が終了コード 0

### T-044: 旧 Step 3 "Find Work" のみのタイトルが残っていないこと
- **テスト名**: 旧 Step 3 タイトル除去
- **テスト方法**:
  ```bash
  grep -c '^### 3\. Find Work$' /Users/ogawa/workspace/mission-control/agents/templates/base.md
  ```
- **期待結果**: `0`
- **合格基準**: 出力が `0`

---

## 6. 存在テスト — cron メッセージ最小化

### T-050: generate_cron_message() が統一された短いメッセージを返すこと
- **テスト名**: worker 用 cron メッセージの最小化
- **テスト方法**:
  ```bash
  # generate_cron_message の中身を確認
  python3 -c "
  import ast, sys
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      tree = ast.parse(f.read())
  for node in ast.walk(tree):
      if isinstance(node, ast.FunctionDef) and node.name == 'generate_cron_message':
          # 関数の行数をカウント（短いこと: 10行以下）
          lines = node.end_lineno - node.lineno + 1
          if lines <= 10:
              print(f'PASS: generate_cron_message is {lines} lines')
          else:
              print(f'FAIL: generate_cron_message is {lines} lines (expected <=10)')
          break
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: 関数が短い（10行以下）

### T-051: generate_cron_message が "AGENTS.md" を参照するメッセージを含むこと
- **テスト名**: cron メッセージに AGENTS.md 参照が含まれる
- **テスト方法**:
  ```bash
  grep -A5 'def generate_cron_message' /Users/ogawa/workspace/mission-control/tools/setup_mission.py | grep 'AGENTS.md'
  ```
- **期待結果**: AGENTS.md への参照が含まれる
- **合格基準**: grep が終了コード 0

### T-052: supervisor 用の個別 cron メッセージ関数も統一されていること
- **テスト名**: monitor/brain/escalator の cron メッセージ統一
- **テスト方法**:
  ```bash
  # 各関数が「AGENTS.md」を参照する統一メッセージであること
  for func in generate_monitor_cron_message generate_brain_cron_message generate_escalator_cron_message; do
    grep -A5 "def $func" /Users/ogawa/workspace/mission-control/tools/setup_mission.py | grep -q 'AGENTS.md' && echo "PASS: $func" || echo "FAIL: $func"
  done
  ```
- **期待結果**: 3つ全て PASS
- **合格基準**: 全 supervisor cron メッセージ関数が AGENTS.md 参照の統一メッセージ

### T-053: cron メッセージに詳細な手順が含まれていないこと
- **テスト名**: cron メッセージの手順排除
- **テスト方法**:
  ```bash
  # generate_cron_message 内に mc コマンドの手順が含まれていないこと
  # 旧メッセージは "checkin" や "list --mine" を含んでいた
  python3 -c "
  import inspect, importlib.util
  spec = importlib.util.spec_from_file_location('setup', '/Users/ogawa/workspace/mission-control/tools/setup_mission.py')
  mod = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(mod)
  msg = mod.generate_cron_message('test-agent', project='proj', mission='mis')
  if 'checkin' in msg or 'list --mine' in msg:
      print(f'FAIL: cron message contains procedure details: {msg}')
  else:
      print(f'PASS: cron message is minimal')
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: cron メッセージに `checkin` や `list --mine` が含まれない

---

## 7. 存在テスト — setup_mission.py 冪等化

### T-060: agent_exists() ヘルパー関数が存在すること
- **テスト名**: agent_exists ヘルパー関数の存在
- **テスト方法**:
  ```bash
  grep -c 'def agent_exists' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: `1`
- **合格基準**: 出力が `1`

### T-061: cron_exists() ヘルパー関数が存在すること
- **テスト名**: cron_exists ヘルパー関数の存在
- **テスト方法**:
  ```bash
  grep -c 'def cron_exists' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: `1`
- **合格基準**: 出力が `1`

### T-062: register_agent() 内で agent_exists() が呼ばれていること
- **テスト名**: register_agent 内の agent 存在確認
- **テスト方法**:
  ```bash
  # register_agent 関数の範囲内で agent_exists が呼ばれていることを確認
  python3 -c "
  import ast
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      source = f.read()
  tree = ast.parse(source)
  for node in ast.walk(tree):
      if isinstance(node, ast.FunctionDef) and node.name == 'register_agent':
          func_source = source.split('\n')[node.lineno-1:node.end_lineno]
          found = any('agent_exists' in line for line in func_source)
          print('PASS' if found else 'FAIL: agent_exists not called in register_agent')
          break
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: register_agent 関数内に agent_exists 呼び出しが存在

### T-063: register_agent() 内で cron_exists() が呼ばれていること
- **テスト名**: register_agent 内の cron 存在確認
- **テスト方法**:
  ```bash
  python3 -c "
  import ast
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      source = f.read()
  tree = ast.parse(source)
  for node in ast.walk(tree):
      if isinstance(node, ast.FunctionDef) and node.name == 'register_agent':
          func_source = source.split('\n')[node.lineno-1:node.end_lineno]
          found = any('cron_exists' in line for line in func_source)
          print('PASS' if found else 'FAIL: cron_exists not called in register_agent')
          break
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: register_agent 関数内に cron_exists 呼び出しが存在

### T-064: main() 末尾に最終検証ステップが存在すること
- **テスト名**: main 関数の最終検証ステップ
- **テスト方法**:
  ```bash
  # "Verify" または "verification" に関連する検証ロジックが main() 内に存在すること
  grep -i 'verify\|verification\|final.*check' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: 検証関連の文字列が見つかる
- **合格基準**: grep が終了コード 0

### T-065: 最終検証が agent_exists と cron_exists を使用していること
- **テスト名**: 最終検証のヘルパー関数使用
- **テスト方法**:
  ```bash
  # main() 関数末尾付近で agent_exists と cron_exists が呼ばれていること
  python3 -c "
  import ast
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      source = f.read()
  tree = ast.parse(source)
  for node in ast.walk(tree):
      if isinstance(node, ast.FunctionDef) and node.name == 'main':
          # main 関数の後半 (最後の30行) を確認
          func_lines = source.split('\n')[node.lineno-1:node.end_lineno]
          tail = func_lines[-30:]
          has_agent = any('agent_exists' in l for l in tail)
          has_cron = any('cron_exists' in l for l in tail)
          if has_agent and has_cron:
              print('PASS')
          else:
              print(f'FAIL: agent_exists={has_agent}, cron_exists={has_cron} in main() tail')
          break
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: main() 末尾で両方のヘルパー関数が使用されている

---

## 8. 整合性テスト

### T-070: mc CLI の dispatch テーブルと help テキストの cron-guard 整合性
- **テスト名**: dispatch テーブルと help の整合性
- **テスト方法**:
  ```bash
  # dispatch テーブルに cron-guard が存在
  dispatch=$(grep -c 'cron-guard).*cmd_cron_guard' /Users/ogawa/workspace/mission-control/mc)
  # help テキストに cron-guard が存在
  help_text=$(grep -c 'cron-guard' /Users/ogawa/workspace/mission-control/mc)
  # 両方存在
  if [ "$dispatch" -ge 1 ] && [ "$help_text" -ge 3 ]; then
    echo "PASS: dispatch=$dispatch, help_refs=$help_text"
  else
    echo "FAIL: dispatch=$dispatch, help_refs=$help_text"
  fi
  ```
- **期待結果**: `PASS`
- **合格基準**: dispatch テーブルに1件、help テキストに3件以上（disable/enable/check）

### T-071: cron-guard の DB 不要コマンドリストと dispatch テーブルの整合性
- **テスト名**: DB 不要リストと dispatch の整合性
- **テスト方法**:
  ```bash
  # DB不要リストに含まれていること
  no_db=$(grep 'init|help.*cron-guard' /Users/ogawa/workspace/mission-control/mc | wc -l)
  # dispatch テーブルに含まれていること
  dispatch=$(grep 'cron-guard).*cmd_cron_guard' /Users/ogawa/workspace/mission-control/mc | wc -l)
  if [ "$no_db" -ge 1 ] && [ "$dispatch" -ge 1 ]; then
    echo "PASS"
  else
    echo "FAIL: no_db=$no_db, dispatch=$dispatch"
  fi
  ```
- **期待結果**: `PASS`
- **合格基準**: 両方に登録されている

### T-072: cmd_cron_guard が disable/enable/check の3サブコマンドを処理すること
- **テスト名**: cron-guard の3サブコマンドの case 分岐
- **テスト方法**:
  ```bash
  for sub in disable enable check; do
    grep -q "${sub})" /Users/ogawa/workspace/mission-control/mc && echo "PASS: $sub" || echo "FAIL: $sub missing from case"
  done
  ```
- **期待結果**: 3つ全て PASS
- **合格基準**: disable/enable/check 全てが case 分岐に存在

### T-073: setup_mission.py の全 cron メッセージ関数が存在すること
- **テスト名**: cron メッセージ関数の完全性
- **テスト方法**:
  ```bash
  for func in generate_cron_message generate_monitor_cron_message generate_brain_cron_message generate_escalator_cron_message; do
    grep -q "def $func" /Users/ogawa/workspace/mission-control/tools/setup_mission.py && echo "PASS: $func" || echo "FAIL: $func"
  done
  ```
- **期待結果**: 4つ全て PASS
- **合格基準**: 全 cron メッセージ生成関数が存在

---

## 9. 仕様適合テスト

### T-080: 仕様 5.1.1 — mc cron-guard コマンドの仕様準拠
- **テスト名**: cron-guard コマンドが仕様の3操作を全てサポート
- **テスト方法**:
  ```bash
  # 仕様: mc cron-guard disable <agent-name>
  # 仕様: mc cron-guard enable <agent-name>
  # 仕様: mc cron-guard check <agent-name>
  grep 'openclaw.*cron disable' /Users/ogawa/workspace/mission-control/mc | grep -v 'templates\|setup_mission'
  grep 'openclaw.*cron enable' /Users/ogawa/workspace/mission-control/mc | grep -v 'templates\|setup_mission'
  grep "enabled.*disabled" /Users/ogawa/workspace/mission-control/mc
  ```
- **期待結果**: disable は `openclaw ... cron disable` を呼び、enable は `openclaw ... cron enable` を呼び、check はステータスを表示
- **合格基準**: 3操作全てが実装されている

### T-081: 仕様 5.1.1 — OPENCLAW_PROFILE 自動参照
- **テスト名**: cron-guard が OPENCLAW_PROFILE を使用
- **テスト方法**:
  ```bash
  grep 'OPENCLAW_PROFILE' /Users/ogawa/workspace/mission-control/mc | grep -A1 'cmd_cron_guard\|cron_guard'
  ```
  または cmd_cron_guard 関数内で oc_profile_flag を構築していること:
  ```bash
  sed -n '/^cmd_cron_guard/,/^cmd_/p' /Users/ogawa/workspace/mission-control/mc | grep 'OPENCLAW_PROFILE'
  ```
- **期待結果**: OPENCLAW_PROFILE が参照されている
- **合格基準**: cmd_cron_guard 内で OPENCLAW_PROFILE を使用

### T-082: 仕様 5.1.2 — テンプレートの Cron Guard が1行コマンドであること
- **テスト名**: テンプレートの Cron Guard が1行
- **テスト方法**:
  ```bash
  for tmpl in base.md brain.md monitor.md escalator.md; do
    path="/Users/ogawa/workspace/mission-control/agents/templates/$tmpl"
    # mc cron-guard の行を取得し、各行が1コマンド（パイプや && を含まない）であること
    lines=$(grep 'mc cron-guard' "$path" | grep -c '&&\||')
    if [ "$lines" -eq 0 ]; then
      echo "PASS: $tmpl — cron-guard commands are single-line"
    else
      echo "FAIL: $tmpl — $lines lines contain pipes or chaining"
    fi
  done
  ```
- **期待結果**: 4つ全て PASS
- **合格基準**: 全テンプレートで mc cron-guard コマンドが単一コマンド（パイプや && なし）

### T-083: 仕様 5.1.3 — base.md in_progress が仕様通りの構造
- **テスト名**: in_progress 再開ロジックの仕様準拠
- **テスト方法**:
  ```bash
  # 仕様: 1. in_progress 確認 → 2. pending 確認 → 3. unclaimed 確認
  path="/Users/ogawa/workspace/mission-control/agents/templates/base.md"
  ip=$(grep -n 'in_progress' "$path" | head -1 | cut -d: -f1)
  pend=$(grep -n 'mine.*pending\|pending.*mine' "$path" | head -1 | cut -d: -f1)
  unclaimed=$(grep -n 'list --status pending' "$path" | grep -v 'mine' | head -1 | cut -d: -f1)

  if [ -n "$ip" ] && [ -n "$pend" ] && [ -n "$unclaimed" ]; then
    if [ "$ip" -lt "$pend" ] && [ "$pend" -lt "$unclaimed" ]; then
      echo "PASS: order is in_progress($ip) < pending($pend) < unclaimed($unclaimed)"
    else
      echo "FAIL: wrong order ip=$ip pend=$pend unclaimed=$unclaimed"
    fi
  else
    echo "FAIL: missing elements ip=$ip pend=$pend unclaimed=$unclaimed"
  fi
  ```
- **期待結果**: `PASS`
- **合格基準**: in_progress → pending (mine) → pending (all) の順序

### T-084: 仕様 5.1.4 — cron メッセージが Single Source of Truth を AGENTS.md に統一
- **テスト名**: cron メッセージの AGENTS.md 統一
- **テスト方法**:
  ```bash
  python3 -c "
  import importlib.util
  spec = importlib.util.spec_from_file_location('setup', '/Users/ogawa/workspace/mission-control/tools/setup_mission.py')
  mod = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(mod)

  # 全4関数のメッセージを取得
  msgs = []
  msgs.append(('worker', mod.generate_cron_message('test-agent', 'proj', 'mis')))
  msgs.append(('monitor', mod.generate_monitor_cron_message('test-monitor', 'proj', 'mis')))
  msgs.append(('brain', mod.generate_brain_cron_message('test-brain', 'proj', 'mis')))
  msgs.append(('escalator', mod.generate_escalator_cron_message('test-escalator', 'proj', 'mis')))

  all_pass = True
  for name, msg in msgs:
      if 'AGENTS.md' in msg:
          print(f'PASS: {name} references AGENTS.md')
      else:
          print(f'FAIL: {name} does not reference AGENTS.md: {msg[:80]}...')
          all_pass = False

  if all_pass:
      print('ALL PASS')
  "
  ```
- **期待結果**: `ALL PASS`
- **合格基準**: 全4関数が AGENTS.md を参照

### T-085: 仕様 5.1.5 — setup_mission.py の冪等性設計
- **テスト名**: register_agent の冪等性パターン
- **テスト方法**:
  ```bash
  # agent 登録前に存在確認をしていること
  # cron 登録前に存在確認をしていること
  python3 -c "
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      source = f.read()

  # register_agent 内で if agent_exists / if cron_exists のパターンがあること
  import re
  func_match = re.search(r'def register_agent\(.*?\n(.*?)(?=\ndef |\Z)', source, re.DOTALL)
  if func_match:
      body = func_match.group(1)
      has_agent_check = 'agent_exists' in body
      has_cron_check = 'cron_exists' in body
      if has_agent_check and has_cron_check:
          print('PASS: register_agent has idempotency checks')
      else:
          print(f'FAIL: agent_check={has_agent_check}, cron_check={has_cron_check}')
  else:
      print('FAIL: register_agent function not found')
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: register_agent に agent_exists と cron_exists の両方のチェックが存在

---

## 10. 冪等性テスト

### T-090: agent_exists() が正しいシグネチャを持つこと
- **テスト名**: agent_exists 関数シグネチャ
- **テスト方法**:
  ```bash
  grep 'def agent_exists' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: `agent_id` と `oc_profile_flag` をパラメータに取り、`bool` を返す関数定義
- **合格基準**: 関数定義が仕様準拠

### T-091: cron_exists() が正しいシグネチャを持つこと
- **テスト名**: cron_exists 関数シグネチャ
- **テスト方法**:
  ```bash
  grep 'def cron_exists' /Users/ogawa/workspace/mission-control/tools/setup_mission.py
  ```
- **期待結果**: `agent_id` と `oc_profile_flag` をパラメータに取り、`bool` を返す関数定義
- **合格基準**: 関数定義が仕様準拠

### T-092: agent_exists() が例外発生時に安全に False を返すこと
- **テスト名**: agent_exists のエラー耐性
- **テスト方法**:
  ```bash
  # check=False が使われていること（コマンド失敗時に例外を投げない）
  python3 -c "
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      source = f.read()
  import re
  match = re.search(r'def agent_exists.*?(?=\ndef )', source, re.DOTALL)
  if match:
      body = match.group()
      if 'check=False' in body or 'try' in body:
          print('PASS: agent_exists handles errors safely')
      else:
          print('FAIL: agent_exists may throw on command failure')
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: コマンド失敗時に安全に動作

### T-093: cron_exists() が JSON パースエラー時に安全に False を返すこと
- **テスト名**: cron_exists のエラー耐性
- **テスト方法**:
  ```bash
  python3 -c "
  with open('/Users/ogawa/workspace/mission-control/tools/setup_mission.py') as f:
      source = f.read()
  import re
  match = re.search(r'def cron_exists.*?(?=\ndef )', source, re.DOTALL)
  if match:
      body = match.group()
      has_try = 'try' in body
      has_except = 'except' in body and ('JSONDecodeError' in body or 'Exception' in body)
      if has_try and has_except:
          print('PASS: cron_exists handles JSON parse errors')
      else:
          print(f'FAIL: try={has_try}, except_json={has_except}')
  "
  ```
- **期待結果**: `PASS`
- **合格基準**: JSONDecodeError をキャッチして False を返す

---

## 11. ベストエフォートテスト

### T-100: mc cron-guard が cron 未発見時にエラー終了しないこと
- **テスト名**: cron-guard ベストエフォート（cron 未発見）
- **テスト方法**:
  ```bash
  # cmd_cron_guard 関数内で、cron_id が空の場合に return 0 していること
  sed -n '/^cmd_cron_guard/,/^[a-z]/p' /Users/ogawa/workspace/mission-control/mc | grep -A1 'No cron job found' | grep 'return 0'
  ```
- **期待結果**: `return 0` が見つかる
- **合格基準**: cron job 未発見時に return 0

### T-101: mc cron-guard disable 失敗時にエラー終了しないこと
- **テスト名**: cron-guard disable ベストエフォート
- **テスト方法**:
  ```bash
  # disable の case ブランチで || パターン（失敗時の代替処理）が使われていること
  sed -n '/^cmd_cron_guard/,/^[a-z]/p' /Users/ogawa/workspace/mission-control/mc | sed -n '/disable)/,/;;/p' | grep '||'
  ```
- **期待結果**: `||` によるフォールバックパターンが見つかる
- **合格基準**: disable 失敗が非致命的

### T-102: mc cron-guard enable 失敗時にエラー終了しないこと
- **テスト名**: cron-guard enable ベストエフォート
- **テスト方法**:
  ```bash
  sed -n '/^cmd_cron_guard/,/^[a-z]/p' /Users/ogawa/workspace/mission-control/mc | sed -n '/enable)/,/;;/p' | grep '||'
  ```
- **期待結果**: `||` によるフォールバックパターンが見つかる
- **合格基準**: enable 失敗が非致命的

### T-103: テンプレートに「skip and continue」等のベストエフォート指示があること
- **テスト名**: テンプレートのベストエフォート指示
- **テスト方法**:
  ```bash
  for tmpl in base.md brain.md monitor.md escalator.md; do
    path="/Users/ogawa/workspace/mission-control/agents/templates/$tmpl"
    grep -qi 'skip.*continue\|best.effort\|fail.*skip\|fails.*skip' "$path" && echo "PASS: $tmpl" || echo "FAIL: $tmpl — no best-effort instruction"
  done
  ```
- **期待結果**: 全テンプレートが PASS（少なくとも1つのベストエフォート指示が存在）
- **合格基準**: 全4テンプレートにベストエフォートの指示が記載

---

## 12. 網羅性テスト（横断）

### T-110: 旧ワンライナーパターンがプロジェクト全体から除去されていること
- **テスト名**: プロジェクト全体の旧パターン残存チェック
- **テスト方法**:
  ```bash
  # agents/templates/ と tools/setup_mission.py の両方で旧パターンが存在しないこと
  count=0
  count=$((count + $(grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/base.md 2>/dev/null || echo 0)))
  count=$((count + $(grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/brain.md 2>/dev/null || echo 0)))
  count=$((count + $(grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/monitor.md 2>/dev/null || echo 0)))
  count=$((count + $(grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/agents/templates/escalator.md 2>/dev/null || echo 0)))
  count=$((count + $(grep -c 'openclaw.*cron list.*json.*python3' /Users/ogawa/workspace/mission-control/tools/setup_mission.py 2>/dev/null || echo 0)))

  if [ "$count" -eq 0 ]; then
    echo "PASS: 0 legacy one-liners found"
  else
    echo "FAIL: $count legacy one-liners still exist"
  fi
  ```
- **期待結果**: `PASS: 0 legacy one-liners found`
- **合格基準**: 旧パターンの残存が 0 件

### T-111: Tier 1 変更対象ファイルの完全性チェック
- **テスト名**: 変更対象ファイルの全存在確認
- **テスト方法**:
  ```bash
  files=(
    "/Users/ogawa/workspace/mission-control/mc"
    "/Users/ogawa/workspace/mission-control/tools/setup_mission.py"
    "/Users/ogawa/workspace/mission-control/agents/templates/base.md"
    "/Users/ogawa/workspace/mission-control/agents/templates/brain.md"
    "/Users/ogawa/workspace/mission-control/agents/templates/monitor.md"
    "/Users/ogawa/workspace/mission-control/agents/templates/escalator.md"
  )
  for f in "${files[@]}"; do
    [ -f "$f" ] && echo "OK: $f" || echo "MISSING: $f"
  done
  ```
- **期待結果**: 全ファイルが OK
- **合格基準**: MISSING が 0 件

---

## テスト集計表

| カテゴリ | テスト範囲 | テスト数 |
|---------|-----------|---------|
| 構文テスト | T-001 〜 T-003 | 3 |
| 存在テスト: mc cron-guard | T-010 〜 T-015 | 6 |
| 存在テスト: テンプレート Cron Guard | T-020 〜 T-028 | 9 |
| 非存在テスト: 旧ワンライナー除去 | T-030 〜 T-036 | 7 |
| 存在テスト: in_progress 再開 | T-040 〜 T-044 | 5 |
| 存在テスト: cron メッセージ最小化 | T-050 〜 T-053 | 4 |
| 存在テスト: 冪等化ヘルパー | T-060 〜 T-065 | 6 |
| 整合性テスト | T-070 〜 T-073 | 4 |
| 仕様適合テスト | T-080 〜 T-085 | 6 |
| 冪等性テスト | T-090 〜 T-093 | 4 |
| ベストエフォートテスト | T-100 〜 T-103 | 4 |
| 網羅性テスト | T-110 〜 T-111 | 2 |
| **合計** | | **60** |

---

## 実行手順

1. 全ての変更が完了した後、上記テストを上から順に実行する
2. 各テストの結果を PASS/FAIL で記録する
3. FAIL が発生した場合、テスト ID と実際の出力を記録して開発者にフィードバックする
4. 全テスト PASS で Tier 1 実装完了とする

## 前提条件

- テスト実行環境に `bash`, `python3`, `grep`, `sed`, `file` コマンドが利用可能であること
- テスト対象ファイルが `/Users/ogawa/workspace/mission-control/` 配下に存在すること
- `openclaw` CLI は実際には呼び出さない（構文・存在テストのみ）
