# Agent B: シンプリシティ仮説

## 仮説

現在の OMOS アーキテクチャは、LLM エージェントが確実に実行するには認知負荷が高すぎる。Cron Guard の `&&`-chain bash ワンライナー、3種の Supervisor 分離、多段階 Phase 管理ロジックの組み合わせにより、単一障害点ではなく「障害面」が形成されており、システムの信頼性は各構成要素の信頼性の積で決まるため急速に劣化する。

---

## 現状の問題点

### 問題 1: Cron Guard の bash ワンライナーが LLM にとって脆弱すぎる

**該当箇所**: 仕様書 Section 7「Cron Guard パターン」、全テンプレート Step 0

**現在の実装**:
```bash
cron_id=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json \
  | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") \
  && openclaw --profile "$OPENCLAW_PROFILE" cron disable "$cron_id"
```

**問題の本質**:
- このワンライナーは `openclaw cron list` → JSON パース → `cron_id` 抽出 → `cron disable` の4ステップを `&&` で連結している
- LLM はこれをコピー&ペーストして実行するが、テンプレート変数 `{agent_id}` のレンダリングミス、引用符の崩れ、python3 ワンライナーの構文エラーなど、**人間プログラマでも間違えやすい箇所**が多い
- 同一パターンが brain.md で **4回**（Step 0, Step 1 の early exit, Step 6 のターゲット cron, Step 7）、base.md で **3回**、monitor.md で **3回**、escalator.md で **3回** 出現 = 合計 **13回** のコピーが全テンプレートに散在
- 各インスタンスで `{agent_id}` がハードコードかターゲットエージェント名かが変わるため、LLM が混乱しやすい
- 仕様書自体が「失敗時はスキップして続行」と記載しており、本機構のベストエフォート性を認めている

**定量的リスク**: 13箇所 x 失敗確率 5% = セッションあたり約 49% の確率で少なくとも1回の Cron Guard 失敗。monitor の Recovery がカバーするとはいえ、そもそも信頼性の低い仕組みを13回繰り返す設計が問題。

### 問題 2: Supervisor 3分割の責務境界が曖昧で冗長

**該当箇所**: 仕様書 Section 6、brain.md / monitor.md / escalator.md

**現在の構造**:
```
monitor: ボード観察 → brain にレポート
brain:   レポート受信 → 判断 → タスク作成/再割り当て
escalator: brain からの依頼 → Slack 投稿
```

**問題点**:
- **monitor → brain の伝言ゲーム**: monitor が「STALE: Task #3」を brain にメッセージ送信 → brain が次回起動時(6時間後)にメッセージを読む → brain が判断 → 対応。この間 **最大12時間** のレイテンシが発生する
- **escalator の存在意義が薄い**: escalator の仕事は「Slack にメッセージを投稿する」だけ。brain が直接 Slack メッセージを送ることは cron の `--announce` で既にやっている。escalator は brain と同じモデル(Sonnet)を使って起動されるが、実質的にはメッセージのリレー役に過ぎない
- **3エージェント分 = 3倍の API コスト**: 6時間ごとに3つの Supervisor が起動 = 1日12回の Supervisor セッション。brain 単体で monitor + escalator の機能を兼務すれば 1日4回で済む
- **情報の非同期性**: monitor が検知した問題を brain が受け取るのは次の brain 起動時。リアルタイム性が必要な場面で致命的な遅延になる

### 問題 3: brain.md の Phase 管理ロジックが複雑すぎる

**該当箇所**: brain.md Step 2.5「Plan Review & Phase Management」

**現在のロジック** (brain が毎回実行すべき判断フロー):
```
1. plan 存在確認
2. plan あり → A. 進捗アノテーション (plan.md を heredoc で書き換え)
3. B. 現在 Phase の特定 (タスク一覧 vs plan の照合)
4. C-1. Phase 完了 + [PROPOSED] なし → PROPOSE (checkpoint 作成 → mission pause)
5. C-2. Phase 完了 + [PROPOSED] あり → CREATE (タスク作成 + cron 有効化)
6. Auto: true 例外 → PROPOSE スキップ
7. plan なし → 直接タスク管理モード
```

**問題点**:
- brain は LLM エージェントである。このフローチャートを AGENTS.md から毎回正確に読み解き、状態を判定し、正しい分岐に入ることを期待している
- plan.md の `- [ ]` → `- [x]` への書き換え、`[PROPOSED]` タグの付与と除去、heredoc による plan.md 全体の上書きなど、**plan.md をプログラム的に操作する作業**を LLM に委ねている
- 特に「C-1: PROPOSE」は checkpoint 作成 → claim → start → done の4コマンドを連続実行する必要がある
- `Auto: true` の例外処理が条件分岐をさらに複雑にしている

**認知負荷の定量化**: brain.md は約 215 行。LLM のコンテキストウィンドウ的には問題ないが、**1回の起動で判断すべき条件分岐が 7 パターン以上** あり、各分岐で異なる bash コマンド列を正確に生成する必要がある。

### 問題 4: mc-architect の Step 数と状態管理

**該当箇所**: 仕様書 Section 2「動作フロー」、AGENTS.md

**現在の Step**:
```
Step 0:   Profile 検出
Step 1:   ミッション分析
Step 2:   チーム設計
Step 3:   roles.json 作成 (任意)
Step 3.5: 監視ポリシー (任意)
Step 3.7: plan.md 作成 ★必須★
Step 3.8: Slack でユーザー承認待ち ★必須★
Step 4:   setup_mission 実行
Step 5:   brain 起動 (任意)
Step 6:   完了報告
```

**問題点**:
- Step 番号が `3 → 3.5 → 3.7 → 3.8 → 4` と非整数番号が並ぶ。これは仕様の有機的成長を示しているが、LLM にとっては「次のステップはどれか」の判断を難しくする
- Step 3.8 でセッションが一度中断し、ユーザー承認後に Step 4 から再開する。LLM は前回のセッションコンテキスト（profile 値、project/mission 名、plan の内容）を**次のセッションに引き継げない**。Slack 経由で再度呼び出された際、Step 0 からやり直して状態を復元する必要がある
- Step 3.7 の plan.md 作成は `/tmp/` にファイルを書き出す操作を含む。LLM は bash の heredoc で plan.md を生成するが、plan の内容にシェル特殊文字（`$`, `!`, バッククォート等）が含まれると壊れる可能性がある
- AGENTS.md は約 440行 あり、同じ情報（mc コマンドリファレンス、Safety Rules）が仕様書と二重管理されている

### 問題 5: 外部依存サービスの障害点列挙

**該当箇所**: システム全体

現在のアーキテクチャで壊れうる箇所を網羅的に列挙する:

| # | 障害点 | 影響範囲 | 発生頻度(推定) |
|---|--------|---------|---------------|
| 1 | `openclaw cron list --json` のレスポンス形式変更 | 全エージェントの Cron Guard 破壊 | 低(API変更時) |
| 2 | `openclaw` gateway タイムアウト | Cron Guard 失敗、cron 無効のまま放置 | 中(ネットワーク依存) |
| 3 | python3 ワンライナーのJSON パースエラー | cron_id 取得失敗 | 低 |
| 4 | `mc` CLI のレスポンス形式変更 | タスク管理全般の破壊 | 低 |
| 5 | Slack webhook/API のレート制限 | エスカレーション遅延 | 中 |
| 6 | LLM が Cron Guard ワンライナーを誤生成 | cron 二重実行 or 永久停止 | 中〜高 |
| 7 | LLM が Phase 状態を誤判定 | 不要なタスク作成、Phase スキップ | 中 |
| 8 | LLM が plan.md の heredoc 書き換えで内容を破損 | Phase 管理の崩壊 | 中 |
| 9 | monitor → brain 間のメッセージ配送遅延 (最大12時間) | 問題対応の遅延 | 確実(仕様上) |
| 10 | brain → escalator 間のメッセージ配送遅延 | 人間への通知遅延 | 確実(仕様上) |
| 11 | `$OPENCLAW_PROFILE` 未設定 | 全エージェントの config 参照先誤り | 低 |
| 12 | `/tmp/<project>-plan.md` の残存/上書き | 別ミッションの plan が混入 | 中 |
| 13 | cron ジョブの重複登録 | 同一エージェントの多重起動 | 低 |
| 14 | setup_mission の部分失敗(3エージェント目で失敗等) | 不完全なチーム構成 | 低〜中 |
| 15 | `mc fleet` の `last_seen` がタイムゾーンずれ | Stale 検知の誤判定 | 低 |

合計 **15箇所** の障害点が存在する。特に #6, #7, #8 は LLM の生成精度に直接依存するため、システム改善だけでは対処できない。

### 問題 6: テンプレートの肥大化とコンテキスト消費

**該当箇所**: 全テンプレート

| テンプレート | 行数 | Cron Guard コピー数 | 推定トークン数 |
|------------|------|-------------------|-------------|
| brain.md | 215行 | 4回 | ~3,500 |
| base.md | 104行 | 3回 | ~1,700 |
| monitor.md | 99行 | 3回 | ~1,600 |
| escalator.md | 99行 | 3回 | ~1,600 |
| architect AGENTS.md | 443行 | 0回 | ~7,000 |

- Cron Guard のワンライナー(約120文字)が各テンプレートに3-4回コピーされ、テンプレートの約 15-20% を占めている
- brain.md の Phase 管理セクション(Step 2.5)だけで約 60行 = テンプレートの 28% を占める
- これらはエージェントの**毎回のセッション開始時**に AGENTS.md として読み込まれ、コンテキストウィンドウを消費する

---

## 改善提案

### 提案 1: Cron Guard をシェルスクリプトに外出しする

**現在**: 各テンプレートに120文字のワンライナーが 3-4 回ハードコード

**改善**: `mc` CLI に `cron-guard` サブコマンドを追加し、ワンライナーを1コマンドに圧縮

```bash
# 現在 (LLM が毎回正確に生成する必要あり)
cron_id=$(openclaw --profile "$OPENCLAW_PROFILE" cron list --json \
  | python3 -c "import sys,json; [print(j['id']) for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='{agent_id}']") \
  && openclaw --profile "$OPENCLAW_PROFILE" cron disable "$cron_id"

# 改善後 (LLM は1コマンドを実行するだけ)
mc cron-guard disable {agent_id}
mc cron-guard enable {agent_id}
mc cron-guard enable <target-agent-id>
```

**実装案** (`mc` CLI への追加):
```python
# mc cron-guard disable <agent-name>
def cron_guard_disable(agent_name: str):
    """Disable cron for the named agent. Best-effort, returns 0 even on failure."""
    try:
        result = subprocess.run(
            f'openclaw --profile "$OPENCLAW_PROFILE" cron list --json',
            shell=True, capture_output=True, text=True
        )
        jobs = json.loads(result.stdout).get('jobs', [])
        for job in jobs:
            if job.get('name') == agent_name:
                subprocess.run(
                    f'openclaw --profile "$OPENCLAW_PROFILE" cron disable "{job["id"]}"',
                    shell=True
                )
                return
    except Exception:
        pass  # Best-effort — failure is acceptable
```

**効果**:
- テンプレートの Cron Guard 関連行が 13箇所 x 3行 → 13箇所 x 1行 に削減
- python3 ワンライナーの構文エラーリスクを排除
- `&&` チェーンの必要性を排除(シェル変数の引き継ぎ問題を CLI 内部で吸収)
- LLM が生成ミスする確率を大幅に低下

**テンプレート変更例** (brain.md Step 0):
```markdown
### 0. Cron Guard (Prevent Duplicate Runs)
\```bash
mc cron-guard disable {agent_id}
\```
If this fails, skip and continue.
```

### 提案 2: Supervisor を brain 単一に統合する

**現在**: monitor(観察) + brain(判断) + escalator(通知) の3エージェント

**改善**: brain が monitor と escalator の機能を内包する

**理由**:
- monitor の「観察 → レポート」と brain の「レポート受信 → 判断」の間のレイテンシ (最大6時間) が無意味
- brain が自分で `board` と `fleet` を見て判断すれば、monitor を経由する必要がない (実際、brain.md の Step 3 で既に `board` を確認している)
- escalator の Slack 投稿は cron の `--announce` で既に実現されている。brain がセッション出力で「人間への質問」を出力すれば、cron announce 経由で Slack に届く

**統合 brain のワークフロー**:
```markdown
### 0. Cron Guard
mc cron-guard disable {agent_id}

### 1. Check In + Mission Status
mc -p {project} -m {mission} checkin
(PAUSED/COMPLETED/ARCHIVED → cron-guard enable → stop)
mc -p {project} -m {mission} mission status

### 2. Observe (旧 monitor の機能)
mc -p {project} -m {mission} board
mc -p {project} fleet
mc -p {project} -m {mission} inbox --unread
→ blocked/stale タスク検知
→ stale agent cron recovery: mc cron-guard enable <agent-id>

### 3. Plan & Phase Management (簡素化版 — 後述)
...

### 4. Judge and Act
→ タスク完了判定
→ Phase 進行
→ 人間へのエスカレーション(セッション出力に記載 → cron announce で Slack 配信)

### 5. Cron Guard Re-enable
mc cron-guard enable {agent_id}
```

**効果**:
- Supervisor エージェント数: 3 → 1 (API コスト 67% 削減)
- 情報伝達のレイテンシ: 最大 12時間 → 0 (同一セッション内で完結)
- テンプレート数: 4種(brain/monitor/escalator/base) → 2種(brain/base)
- setup_mission の登録処理: 簡素化(3 supervisor → 1 supervisor)

**トレードオフ**: brain のセッション時間が長くなる (monitor + brain + escalator の合計と同等)。ただし3回に分けて起動するオーバーヘッド (セッション確立 x3) がなくなるため、トータルコストは減少する見込み。

### 提案 3: Phase 管理を宣言的な状態マシンに変更する

**現在**: brain が plan.md を直接テキスト操作（heredoc で書き換え、`[PROPOSED]` タグ付与など）

**改善**: mc CLI に Phase 管理コマンドを追加し、brain は宣言的にコマンドを呼ぶだけにする

```bash
# Phase 状態の確認
mc -p {project} -m {mission} phase status
# 出力例:
# Phase 1: "Research" — COMPLETE (4/4 tasks done, criteria met)
# Phase 2: "Implementation" — PROPOSED (awaiting human review)
# Phase 3: "Testing" — PENDING

# Phase のタスクを一括作成 (plan.md から自動読み取り)
mc -p {project} -m {mission} phase create-tasks 2

# Phase の進行を提案 (checkpoint 作成 + mission pause)
mc -p {project} -m {mission} phase propose 2

# Phase の進捗をアノテーション
mc -p {project} -m {mission} phase annotate
```

**brain.md の Step 2.5 簡素化**:
```markdown
### 2.5. Phase Management
\```bash
mc -p {project} -m {mission} phase status
\```

- 現在 Phase が COMPLETE → `mc phase propose <next>` (mission pauses for review)
- 現在 Phase が PROPOSED + mission resumed → `mc phase create-tasks <N>`
- Phase 1 かつ Auto: true → `mc phase create-tasks 1` (直接作成)
- 全 Phase COMPLETE → checkpoint 作成
```

**効果**:
- brain が plan.md を heredoc で直接書き換える必要がなくなる (破損リスク排除)
- Phase 判定ロジックが mc CLI 側に移動し、LLM の判断負荷が軽減
- brain.md の Step 2.5 が 60行 → 15行に削減
- `[PROPOSED]` タグの手動管理が不要に

### 提案 4: mc-architect のステップをリニアに再番号付け

**現在**: Step 0, 1, 2, 3, 3.5, 3.7, 3.8, 4, 5, 6

**改善**:
```
Step 1: Profile 検出
Step 2: ミッション分析 (project/mission/goal/Slack ID)
Step 3: チーム設計 (roles + roles.json)
Step 4: plan.md 作成
Step 5: Slack でプラン提示 → 承認待ち → 停止
--- (ユーザー承認後に再開) ---
Step 6: setup_mission 実行
Step 7: 完了報告
```

**効果**:
- 番号が連続整数になり、LLM が「次のステップ」を間違えにくくなる
- 任意ステップ (3.5 監視ポリシー) を Step 3 の中に統合することで、独立ステップ数を削減
- 小数点ステップという「後から挿入した感」をなくし、仕様の成熟度を示す

### 提案 5: テンプレートの DRY 化

**現在**: Cron Guard パターン、Communication セクション、Safety Rules が各テンプレートにコピペ

**改善**: 共通セクションを別ファイルに外出しし、setup_mission がテンプレートレンダリング時にインクルード

```python
# setup_mission.py に追加
COMMON_SECTIONS = {
    "cron_guard_start": "mc cron-guard disable {agent_id}\nIf this fails, skip and continue.",
    "cron_guard_end": "mc cron-guard enable {agent_id}",
    "cron_guard_target": "mc cron-guard enable <target-agent-id>",
    "checkin_guard": (
        "```bash\nmc -p {project} -m {mission} checkin\n```\n"
        "If PAUSED/COMPLETED/ARCHIVED → `mc cron-guard enable {agent_id}` and stop."
    ),
}
```

テンプレート側:
```markdown
### 0. Cron Guard
{cron_guard_start}

### 1. Check In
{checkin_guard}
```

**効果**:
- Cron Guard の実装変更が1箇所で済む (現在は13箇所)
- テンプレートの行数削減 (各テンプレート 15-25% 削減見込み)
- 仕様変更時の不整合リスク削減

### 提案 6: Worker テンプレートの cron メッセージに完全なワークフローを記載しない

**現在の cron メッセージ** (setup_mission.py L166-173):
```python
f"You are {agent_id}. Read your AGENTS.md, then execute your workflow: "
f"{mc} -p {project} -m {mission} checkin — "
f"if output contains MISSION_PAUSED, MISSION_COMPLETED, or MISSION_ARCHIVED then stop. "
f"Otherwise: {mc} -p {project} -m {mission} list --mine --status pending && "
f"claim and work on your highest-priority task. "
```

**問題**: cron メッセージにワークフローの要約を入れると、AGENTS.md の詳細指示との間に微妙な齟齬が生じうる。LLM はどちらを優先すべきか迷う。

**改善**: cron メッセージは最小限にする
```python
f"You are {agent_id}. Read your AGENTS.md and execute your workflow. 日本語で応答すること。"
```

**効果**: Single Source of Truth が AGENTS.md のみになり、LLM の混乱を防ぐ。

---

## トレードオフ

| 提案 | 得られるもの | 失われるもの |
|------|------------|------------|
| 1. Cron Guard CLI 化 | 信頼性向上、テンプレート簡素化 | mc CLI への追加開発コスト |
| 2. Supervisor 統合 | コスト 67% 削減、レイテンシ削減 | 関心の分離 (monitor が独立していた明確さ)、brain のセッション時間増大 |
| 3. Phase 管理 CLI 化 | plan.md 破損リスク排除、brain 簡素化 | mc CLI への追加開発コスト、mc CLI の責務増大 |
| 4. Step 再番号付け | 可読性向上 | 既存ドキュメント・運用知識との整合性コスト (マイグレーション) |
| 5. テンプレート DRY 化 | 保守性向上、変更コスト削減 | テンプレートの独立性低下 (共通部分の変更が全エージェントに波及) |
| 6. cron メッセージ最小化 | Single Source of Truth 確立 | cron メッセージだけでは何をすべきか読み取れなくなる (AGENTS.md 必読に) |

**最大のトレードオフ**: 提案 2 (Supervisor 統合) は「関心の分離」という設計原則に反する。しかし、LLM エージェントの文脈では「関心の分離」よりも「実行の確実性」が優先されるべき。人間のチームなら3人に分けた方がよいが、LLM は1つのセッションで全てを処理した方が情報のロスがない。

**最大のリスク**: 提案 1, 3 は mc CLI への機能追加を前提とする。mc CLI 自体の開発・保守コストが増加する。ただし、このコストは「確実に動作するプログラムコード」で支払われるため、「LLM が毎回正確に bash を生成する不確実性」よりも圧倒的に制御可能。

---

## 優先度マトリクス

### High (即座に実施すべき)

| 提案 | 理由 | 工数見積 |
|------|------|---------|
| **提案 1: Cron Guard CLI 化** | 障害点 #6 を直接解消。全エージェントの信頼性が向上。mc CLI への追加は小規模 (50行程度) | 1-2時間 |
| **提案 6: cron メッセージ最小化** | 変更コストほぼゼロ。setup_mission.py の1関数を修正するだけ | 15分 |

### Medium (次のイテレーションで実施)

| 提案 | 理由 | 工数見積 |
|------|------|---------|
| **提案 2: Supervisor 統合** | API コスト削減効果が大きいが、brain テンプレートの再設計が必要 | 3-5時間 |
| **提案 5: テンプレート DRY 化** | 保守性改善。提案 1 と組み合わせると効果的 | 2-3時間 |
| **提案 4: Step 再番号付け** | 認知負荷の改善。仕様書と AGENTS.md 両方の更新が必要 | 1-2時間 |

### Low (将来的に検討)

| 提案 | 理由 | 工数見積 |
|------|------|---------|
| **提案 3: Phase 管理 CLI 化** | 効果は大きいが mc CLI への追加開発が最も大規模。提案 2 で brain を統合してからの方が設計しやすい | 5-8時間 |

---

## 結論: 信頼性は「LLM の賢さ」ではなく「仕組みの単純さ」で担保すべき

現在の OMOS は「LLM が複雑なワークフローを正確に実行できる」ことを前提に設計されている。しかし LLM の出力は確率的であり、複雑なワークフローほど正確性が低下する。

**設計原則の転換**:
- 複雑なロジックは **プログラムコード** (mc CLI) に移す → 決定論的に動作
- LLM には **単純な判断** と **単純なコマンド呼び出し** のみを任せる
- エージェント間の情報伝達は **最小化** する → 伝言ゲームのステップを減らす

この原則に基づけば、提案 1 (Cron Guard CLI 化) と提案 2 (Supervisor 統合) だけで、システムの障害点を 15 → 8 に削減でき、API コストも約 50% 削減できる。
