# Agent B（シンプリシティ）の批判的レビュー

> 本レビューの基本姿勢: **問題を解決するために追加された複雑性が、新たな障害点を生まないか** を最重要基準とする。LLM エージェントが実行主体である以上、テンプレートに1行追加するごとに「LLM がその行を正しく実行する確率」が掛け合わされる。ガードレールが多すぎれば、ガードレール自体が障害の温床になる。

---

## Agent A（耐障害性）への評価

### 同意する点

**1. in_progress タスクの優先再開ロジック（提案1）は正しい**

これは我々 Agent B も見逃していた明確な設計バグである。現在の base.md は `--status pending` のみをクエリしており、前回セッションでクラッシュした in_progress タスクが永久に放置される。修正内容も「Step 3 に `mc list --mine --status in_progress` を1行追加する」だけであり、複雑性の増加は最小限で効果は大きい。**全面的に採用すべき。**

**2. setup_mission の冪等性確保（提案3）は正しい方向**

`register_agent` が冪等でないのは明確な実装上の欠陥である。「存在確認 → 未存在時のみ作成」というパターンは定石であり、Python コードの改修なので LLM の不確実性に影響されない。我々の提案でもカバーしていなかった領域であり、**採用すべき。**

**3. 「LLM は指示を正確に実行する」という前提への懐疑（設計哲学）は完全に共有する**

Agent A の補足セクションで述べられている「LLM の出力を信頼せず、検証する」「テンプレートは短く、明確に」「状態は外部に持つ」は我々 Agent B の主張と完全に一致する。特に「テンプレートは短く、明確に」は全提案の評価基準であるべき。

### 反論する点

**1. ファイルロック（提案7）は複雑性に見合わない — むしろ新たな障害点を作る**

Agent A が提案するファイルベースの楽観的ロックは以下の問題を抱えている:

- **LLM が生成すべき bash が爆発的に複雑化する**: 提案されたコードブロックは `stat -f %m`（macOS固有フラグ）、`date +%s`、算術演算 `$(( ))` を含む **15行以上** の bash スクリプトである。これを LLM がテンプレートから毎回正確にコピー実行するのは、現状の Cron Guard ワンライナーよりも **失敗確率が高い**
- **`stat -f %m` はLinux では動かない**: macOS 固有。Linux では `stat -c %Y`。OS 依存性を新たに導入している
- **ロックファイルの残骸リスク**: Agent A 自身が認めているように、30分タイムアウトで「軽減」されるが、排除されない。ロックファイルが残ったまま cron が起動 → 30分タイムアウト待ち → その間エージェントは実質停止。これは **新たなサイレント障害** である
- **根本的な疑問**: Cron Guard の目的は「二重実行防止」であるが、二重実行の実害は「同一タスクの競合 claim」である。**mc CLI 側で claim を排他制御する方が、ファイルロックより確実でシンプル**。Agent A はこの代替案を検討していない

**我々の対案**: `mc cron-guard disable/enable` コマンド化（Agent B 提案1）で bash の複雑性自体を排除する。ファイルロックという新しい仕組みを導入するのではなく、既存の問題をシンプルにする。

**2. セッション状態ファイル（提案8）は in_progress 再開ロジックと重複する**

Agent A 自身が Low 優先度と認定しているが、問題はそれだけではない:

- **二重の状態管理**: mc CLI のタスク状態（pending/in_progress/done）と `.session.{agent_id}.json` の間に不整合が生じる可能性がある。例えば、タスクは mc 上で in_progress だがセッションファイルが消えている、またはその逆
- **LLM に heredoc で JSON を生成させる**: `cat > ... << SESSION_EOF` で JSON を書かせるのは、plan.md の heredoc 書き換えと同じリスクを抱えている。Agent A が問題点3で指摘した問題を、別の場所で再現している
- **提案1（in_progress 再開）が実装されれば不要**: `mc list --mine --status in_progress` が唯一の真実源（Single Source of Truth）であるべき。ファイルベースの状態記録は冗長

**3. brain-monitor 相互監視（提案4）は複雑性の増加に見合わない**

Agent A はこれを High 優先度としているが、反論する:

- **テンプレートに追加されるのは「5行程度」ではない**: 提案を見ると、monitor.md に追加される Self-Health Check は `openclaw cron list --json | python3 -c "..."` という **まさに我々が問題視しているワンライナー** の新しいバリアント。brain.md にも同様のワンライナーが追加される。これは Cron Guard のコピーを **さらに増やす** ことに等しい
- **Supervisor 統合（Agent B 提案2）で問題自体が消える**: brain に monitor の機能を統合すれば、「monitor が死んだら誰が復旧するのか」という問題自体が存在しなくなる。brain が自分で fleet を確認し、stale agent を検知する。相互監視という複雑な仕組みは不要
- **「両方が同時に死ぬ確率は単体の二乗に低下する」は正しいが**: その代わりに「相互監視ロジック自体のバグで片方が誤って相手の cron を操作する」リスクが新たに発生する。カスケード障害の温床になりうる

**4. plan.md の安全書き込み（提案2）は正しい方向だがテンプレートが複雑すぎる**

バックアップ → tmp 書き込み → バリデーション → mv という4ステップは、人間プログラマには自然だが LLM に毎回正確に実行させるのは危険:

- `[ -s ... ] && grep -q ... && mv ... && echo ... || echo ...` という **1行に4つの条件分岐** を詰め込んだワンライナーは、Cron Guard ワンライナーと同レベルの認知負荷
- `diff <(grep ...) <(grep ...)` のプロセス置換は高度な bash 構文であり、LLM が崩す確率が高い
- バックアップファイルが `.bak.20260220150000` のように蓄積され、ディスク管理の新たな問題が生じる

**我々の対案**: Phase 管理を mc CLI にコマンド化する（Agent B 提案3: `mc phase status/propose/create-tasks`）。brain が plan.md を直接書き換える必要性自体を排除する。

### 見逃している点

**1. 「テンプレートの複雑化がLLMの遵守率を下げる」パラドックスを認識しながら、それに正面から対処していない**

Agent A のトレードオフセクションで「ガードレールを増やすことで逆に障害率が上がるパラドックスが存在する」と明記しているにもかかわらず、提案の多くがテンプレートへのステップ追加である。この矛盾を解消する方法は **「テンプレートに追加するのではなく、mc CLI に移す」** 以外にないが、Agent A はこの方向への提案が少ない。

**2. Supervisor 3分割の問題に言及していない**

Agent A は monitor と brain の相互監視を提案しているが、「そもそも3つに分ける必要があるのか」という根本的な問いを発していない。monitor → brain のメッセージ配送遅延（最大12時間）、escalator の存在意義の薄さ、3エージェント分の API コストという問題に触れていない。

**3. Cron Guard ワンライナーの CLI 化を提案していない**

Agent A はファイルロックという追加層で Cron Guard を「強化」しようとしているが、ワンライナー自体の複雑性を低減する方法（CLI 化）を検討していない。問題の根源に対処せず、上にガードレールを積むアプローチ。

---

## Agent C（可観測性・制御フロー）への評価

### 同意する点

**1. 実行トレーサビリティの欠如は正しい問題提起**

「brain がなぜこのタスクを作ったのか」が追跡できないという指摘は正当。ミッション失敗時の根本原因分析が困難であることは実際の運用で必ず問題になる。

**2. plan.md の解釈保証の欠如（問題点3）は核心的な問題**

brain が plan.md の `- [ ] タスク説明 @role [P0]` を自然言語パースしてタスクを作成する現行設計は、解釈エラーの温床であるという分析は鋭い。特に `@role` → `{project}-{mission}-{role}` への展開ミス、priority マッピングミスのリスクは高い。

**3. architect → brain の引き継ぎギャップ（問題点6）は重要な指摘**

plan.md が「何をするか」のリストであり「なぜそうするか」の情報が欠落しているという指摘は、他の2エージェントが見逃していた視点。ただし解決策については異議がある（後述）。

**4. タスク作成検証（提案6）の考え方は正しい**

「作ったタスクが正しいか確認する」というフィードバックループは、低コストで高い安全性を得られる。ただし実装方法には異議がある。

### 反論する点

**1. YAML フロントマター（提案2）は「二重管理問題」を新たに生み出す**

Agent C 自身がトレードオフで認めているが、この問題は深刻:

- **plan.md は Markdown 本文と YAML フロントマターの2つの真実源を持つ**: フロントマターの `tasks` と Markdown 本文の `- [ ] タスク説明` が不整合になった場合、brain はどちらを信頼するのか。「フロントマターを優先」というルールを LLM が常に守る保証はない
- **architect が YAML を正しく書けるか**: architect 自身も LLM である。YAML のインデント、コロン後のスペース、特殊文字のエスケープは LLM が頻繁に間違える。**YAML の構文エラーは Markdown の曖昧さよりも致命的** — パースが完全に失敗する
- **setup_mission.py に YAML バリデーション関数を追加する提案**: これ自体は有用だが、architect がバリデーションを通らない YAML を生成した場合のフォールバックパスが不明確。バリデーション失敗時に architect が YAML を修正できるか？
- **LLM の認知負荷が増加する**: brain は YAML フロントマター + Markdown 本文 + plan のアノテーション状態 という3つの情報源を処理する必要がある。これは認知負荷の増加であり、シンプリシティの原則に反する

**我々の対案**: YAML フロントマターの代わりに、mc CLI にタスク定義を構造化コマンドとして移す。architect は plan.md を Markdown で書き（人間向け）、brain は `mc phase status` / `mc phase create-tasks` で CLI 経由で構造化された情報を取得する。plan.md 内のタスク定義を mc CLI が解析する処理は Python コードとして確実に動作する。

**2. Decision Log（提案1）は LLM に JSON 生成を委ねる点で脆弱**

```bash
echo '{"ts":"'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'","agent":"{agent_id}","type":"<action_type>","detail":"<brief_description>"}' >> "...decision-log.jsonl"
```

この bash コマンドは以下の問題を持つ:

- **シングルクォートとダブルクォートの入れ子**: `'{"ts":"'"$(date ...)"'",..."}'` という引用符の切り替えは bash の中でも最も間違えやすいパターン。LLM がこれを毎回正確に生成する確率は低い
- **`<action_type>` と `<brief_description>` は LLM が埋める**: JSON のキー値として LLM が自由テキストを挿入する。テキストにダブルクォート、バックスラッシュ、改行が含まれると JSON が壊れる
- **壊れた JSON が jsonl ファイルに蓄積される**: 1行でも不正な JSON が混じると、`mc log` コマンドのパーサーが壊れる
- **Agent C 自身がトレードオフで「LLM が正しい JSON を生成しない可能性」を認めている**: 「python3 ワンライナーで JSON 生成を行う」という緩和策を提案しているが、python3 ワンライナー自体が我々が問題視しているパターンそのもの

**根本的な問題**: 可観測性のためのログを、可観測性が欠如している LLM に生成させるのは自己矛盾。ログが必要なら **mc CLI が自動的に記録する** べきであり、LLM に echo で書かせるべきではない。

**3. Phase 状態マシン（提案3）は phase-state.json と plan.md の二重管理**

Agent C は phase-state.json を導入し、brain に python3 ワンライナーで JSON を更新させることを提案しているが:

- **brain に `python3 -c "import json, datetime; ..."` を実行させる**: これは我々が Cron Guard で問題視している python3 ワンライナーの **新しいバリアント** を追加することに等しい。7行の python3 ワンライナーを LLM が毎セッション正確に生成するのか？
- **phase-state.json と plan.md が独立に存在する**: plan.md のアノテーション（`✅`, `🔄`）と phase-state.json の `status` が不整合になる可能性がある。Agent C は「提案4の drift 検知で不整合を検出する」と言うが、不整合を作ってから検知するよりも、**情報源を一つにする** 方がシンプル
- **Agent B 提案3（`mc phase status/create-tasks`）で代替可能**: Phase 状態を mc CLI が管理すれば、ファイルベースの状態管理は不要。mc CLI は Python で確実に動作し、LLM の不確実性に依存しない

**4. Plan Drift 検知（提案4）は自然言語マッチングの精度問題が致命的**

- monitor に plan の各タスクと board のタスクの **文字列マッチング** をさせる提案だが、brain がタスク作成時に微妙に文言を変えることは日常的に起きる。false positive が多発し、`[PLAN_DRIFT]` アラートが乱発される
- YAML フロントマター（提案2）があれば構造化データで比較できるとしているが、提案2自体に問題がある（上述）
- **根本的な問い**: drift を検知するよりも、drift が起きない設計にする方がシンプルではないか。mc CLI が plan.md を解析してタスクを作成する（brain は `mc phase create-tasks` を呼ぶだけ）なら、drift 自体が発生しない

**5. Dashboard コマンド（提案5b）は既存コマンドの組み合わせで十分**

`mc board` + `mc fleet` + `mc plan show` で現状把握は可能。Dashboard コマンドは「あると嬉しい」レベルであり、mc CLI の開発コストに見合わない。ただし、将来的な改善としては否定しない。

### 見逃している点

**1. 提案全体が「テンプレートへの追加」に偏っている**

Agent C の6つの提案のうち、mc CLI の新コマンド追加は補助的な位置づけ（`mc log`, `mc phase`）であり、主要な変更は brain.md や monitor.md へのステップ追加である。これは我々が指摘する「テンプレート肥大化 → LLM 遵守率低下」の悪循環を加速させる。

**2. Supervisor 3分割の問題に触れていない**

Agent A と同様、Agent C も monitor/brain/escalator の3分割を前提として受け入れ、その上で改善を提案している。しかし提案4の Plan Drift 検知は monitor の拡張であり、Supervisor 統合とは相容れない。統合の可能性を検討した形跡がない。

**3. テンプレートの認知負荷を定量的に評価していない**

Agent C は6つの提案で brain.md に少なくとも3つの新セクション（Decision Logging、Plan Parsing Priority、Phase State File 更新、Task Creation Verification）を追加しようとしている。現在の brain.md が 215行であるのに対し、これらの追加で **250-280行** に膨らむ見込み。テンプレートが長くなればなるほど、LLM の後半指示の遵守率が下がるという基本問題を無視している。

**4. 「可観測性のコスト」を過小評価している**

可観測性は確かに重要だが、**各セッションで追加される bash コマンド実行回数** が増えれば、それだけ各セッションの失敗確率も上がる。Decision Log の echo、phase-state.json の python3 更新、drift 検知の比較処理 — これらはすべて「失敗しうるステップ」であり、可観測性を得るために信頼性を犠牲にしている可能性がある。

---

## 三者統合への提案

3つの提案を俯瞰すると、以下の構図が見える:

| Agent | 基本姿勢 | 主な手段 | リスク |
|-------|---------|---------|--------|
| A（耐障害性） | 障害に備える | テンプレートにガードレールを追加 | テンプレート肥大化 → LLM 遵守率低下 |
| B（シンプリシティ） | 障害点自体を減らす | mc CLI に機能を移し、テンプレートを縮小 | mc CLI の開発コスト増 |
| C（可観測性） | 障害を検知する | ログ・状態ファイル・検証ステップを追加 | 二重管理・新たな障害点 |

**最適な統合方針**: Agent B の「mc CLI にロジックを移す」をベースに、Agent A の「クラッシュリカバリの最小限のロジック」と、Agent C の「可観測性を mc CLI レベルで実現する」を組み合わせる。

### 統合設計の原則

**「LLM にやらせること」と「mc CLI にやらせること」を明確に分離する**

| LLM に任せる（テンプレート） | mc CLI に任せる（Python コード） |
|---|---|
| 状況判断（board を見て何をすべきか決める） | Cron Guard の disable/enable |
| タスクの claim/実行/done | Phase 状態の管理と判定 |
| 人間への報告内容の作成 | plan.md の解析とタスク定義の構造化 |
| 異常時のエスカレーション判断 | 実行ログの自動記録 |
| | setup_mission の冪等性 |
| | in_progress タスクの検出 |

### 具体的な統合提案（優先度順）

#### 1. Cron Guard CLI 化 [Agent B 提案1] + ファイルロック不採用 [Agent A 提案7 棄却]

```bash
mc cron-guard disable {agent_id}
mc cron-guard enable {agent_id}
```

- ファイルロックは不要。mc CLI 内部で必要なら実装するが、LLM に bash で書かせない
- テンプレート13箇所のワンライナーが1行コマンドに置換される

#### 2. in_progress タスク再開 [Agent A 提案1 採用] + セッション状態ファイル不採用 [Agent A 提案8 棄却]

base.md Step 3 に以下を追加（Agent A の提案をほぼそのまま採用）:

```markdown
### 3. Resume or Find Work
First, check for in-progress tasks from a previous crashed session:
\```bash
mc -p {project} -m {mission} list --mine --status in_progress
\```
If found → resume it. Otherwise → check pending tasks.
```

- `mc list --mine --status in_progress` が Single Source of Truth
- `.session.{agent_id}.json` は不要（二重管理を避ける）

#### 3. Phase 管理 CLI 化 [Agent B 提案3] + YAML フロントマター不採用 [Agent C 提案2 棄却] + Plan Drift 検知不要 [Agent C 提案4 棄却]

```bash
mc -p {project} -m {mission} phase status        # Phase 状態確認
mc -p {project} -m {mission} phase create-tasks N # plan.md からタスク一括作成
mc -p {project} -m {mission} phase propose N      # Phase 進行提案
```

- mc CLI が plan.md を Python でパースし、タスクを正確に作成する
- brain は `mc phase create-tasks` を呼ぶだけ — 自然言語パースのリスクを排除
- YAML フロントマターの二重管理を回避。plan.md は Markdown のまま（人間にも LLM にも読みやすい）
- Plan Drift は「drift が起きない設計」で対処。検知より予防

#### 4. setup_mission 冪等化 [Agent A 提案3 採用]

- Python コードの改修であり LLM の不確実性に影響されない
- 存在確認 → 未存在時のみ作成 パターンで安全なリトライを実現

#### 5. Supervisor 統合 [Agent B 提案2] — 相互監視不採用 [Agent A 提案4 棄却]

brain が monitor + escalator の機能を内包する:

- monitor の「board + fleet 確認 → stale 検知」を brain の Step 2 に統合
- escalator の「Slack 通知」を cron の `--announce` で代替
- API コスト 67% 削減、情報伝達レイテンシ 0

相互監視は不要 — 監視すべき対象が brain 1つに集約されるため。brain のクラッシュリカバリは cron の再起動と mc CLI レベルの状態管理で対処。

#### 6. mc CLI レベルの自動ログ [Agent C の方向性を採用、ただし実装方法を変更]

Agent C の Decision Log のコンセプトは採用するが、**LLM に echo で JSON を書かせるのではなく、mc CLI が自動的に記録する**:

```python
# mc CLI の内部で、重要なコマンド実行を自動的に jsonl に記録
# mc add, mc done, mc phase propose 等の実行時に自動で decision-log.jsonl に追記
def log_action(project, agent, action_type, detail):
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

#### 7. cron メッセージ最小化 [Agent B 提案6] + テンプレート DRY 化 [Agent B 提案5]

- Single Source of Truth を AGENTS.md に統一
- 共通セクションの外出しで保守性向上

### 統合後のテンプレートサイズ予測

| テンプレート | 現在 | Agent A 適用後 | Agent C 適用後 | 統合提案後 |
|---|---|---|---|---|
| brain.md | 215行 | ~280行 (+30%) | ~280行 (+30%) | ~120行 (-44%) |
| base.md | 104行 | ~130行 (+25%) | ~110行 (+6%) | ~70行 (-33%) |
| monitor.md | 99行 | ~130行 (+31%) | ~120行 (+21%) | 廃止（brain に統合） |
| escalator.md | 99行 | ~110行 (+11%) | ~105行 (+6%) | 廃止（brain に統合） |
| テンプレート合計 | 517行 | ~650行 | ~615行 | ~190行 (-63%) |

テンプレートの総行数が 63% 削減されるということは、LLM が毎セッションで処理すべき指示量が 63% 削減されるということであり、**遵守率の大幅な向上** が期待できる。

---

## 絶対に譲れない点

シンプリシティの観点から、どのような最終設計であっても以下の原則は譲れない:

### 原則 1: LLM に bash ワンライナーを生成させない

Cron Guard の `openclaw cron list --json | python3 -c "..."` パターンは、テンプレートから完全に排除する。mc CLI のコマンド1つで同じことを実現する。新しい python3 ワンライナー（phase-state.json の更新、Decision Log の echo 等）を追加する提案は、この原則に反するため受け入れない。

### 原則 2: 状態の真実源は1つだけ

plan.md + YAML フロントマター + phase-state.json + decision-log.jsonl のように状態の情報源が増えるたびに、不整合のリスクが乗算される。Phase 状態は mc CLI が一元管理し、plan.md は人間向けのドキュメントとして位置づける。

### 原則 3: テンプレートは短く保つ

テンプレートに追加するステップは、それが **テンプレートの他の部分の削減** を伴わない限り、原則として反対する。「あると安全」なガードレールでも、テンプレートが10行増えれば他の指示の遵守率が下がる。トレードオフを常に意識する。

### 原則 4: 信頼性は「プログラムコード」で担保する

LLM の出力は確率的である。確実に動作すべきロジック（Cron Guard、Phase 管理、タスク作成、ログ記録）は Python コード（mc CLI）に移す。LLM には「判断」と「単純なコマンド呼び出し」のみを任せる。

### 原則 5: 問題を解決するために新たな問題を作らない

ファイルロック → ロックファイル残骸。セッション状態ファイル → mc タスク状態との二重管理。YAML フロントマター → Markdown 本文との不整合。Decision Log の echo → 壊れた JSON の蓄積。これらはすべて「問題を解決するために新たな障害点を作る」パターンであり、受け入れない。

---

## 総括

Agent A は「障害に備える」、Agent C は「障害を検知する」方向の提案だが、いずれもテンプレートへのステップ追加が主な手段であり、**LLM の認知負荷を増加させる** という共通の副作用を持つ。我々 Agent B は「障害点自体を減らす」アプローチを取り、mc CLI にロジックを移すことでテンプレートを縮小する。

3者の提案で **全員が一致** しているのは:

1. 現状の Cron Guard ワンライナーは問題がある
2. in_progress タスクの再開ロジックが欠落している
3. LLM の出力を信頼しすぎている
4. Phase 管理が複雑すぎる

この4点の合意を出発点に、**解決手段の選択** で議論を進めるべきである。我々の主張は一貫している — **複雑なロジックは LLM ではなくプログラムに任せろ。**
