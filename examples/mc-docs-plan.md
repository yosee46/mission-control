# Mission Plan: docs

## Goal
Mission Control (mc CLI) の使い方ガイドとplan.md運用ガイドを作成する。
成果物は {config_dir}/projects/mc-docs/ 配下に Markdown で配置。

## Agents
- researcher: 既存コード・テンプレートの調査担当
- coder: ドキュメント執筆担当

## Phase 1: Investigation
Timeline: Day 0
Auto: true

### Tasks
- [ ] mc CLI の全サブコマンドとオプションを調査し、コマンド一覧表を作成 @researcher [P1]
- [ ] brain/monitor/escalator テンプレートの仕組みを調査し要約 @researcher [P1]
- [ ] setup_mission.py の引数と出力を調査 @researcher

### Success Criteria
- コマンド一覧表が docs/mc-commands.md として存在する
- テンプレート要約が docs/agent-templates.md として存在する

## Phase 2: Documentation
Timeline: Day 1

### Tasks
- [ ] クイックスタートガイド（初回セットアップからミッション完了まで）を執筆 @coder [P1]
- [ ] plan.md 運用ガイド（フォーマット仕様・フェーズ遷移フロー）を執筆 @coder [P1]
- [ ] 全ドキュメントのリンク整合性とコマンド例の動作確認 @coder --type checkpoint

### Success Criteria
- docs/quickstart.md が存在し、コピペで実行可能なコマンド例を含む
- docs/plan-guide.md が存在する
