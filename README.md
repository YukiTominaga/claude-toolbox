# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個 |
| `agents/` | `spec-critic`, `verifier` |
| `commands/` | `/learn`, `/spec`, `/goal`, `/eval` |
| `hooks/` | `hooks.json` + スクリプト 10 本(破壊コマンドガード / format-on-save / lint / bash ログ / stop-gate / goal-gate / subagent-gate / session-rules / session-learnings / audit-config) |
| `scripts/` | 手動実行系スクリプト(`eval-run.sh`) |
| `rules/` | コーディング規約・テスト方針など(SessionStart hook `session-rules.sh` が全セッションに自動注入) |
| `templates/` | spec / goal / eval-case テンプレート |

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、`~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール

```bash
claude plugin marketplace add YukiTominaga/claude-toolbox
claude plugin install crystal@yuki --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn` / `crystal:goal` / `crystal:eval`
- サブエージェント: `crystal:spec-critic` / `crystal:verifier`
- スキル 11 個は `crystal` 由来でロード
- hooks(SessionStart/PreToolUse/PostToolUse/SubagentStop/Stop)が自動登録され、
  `rules/*.md` はセッション開始時に自動でコンテキストへ注入される

## Loop Engineering (goal ループ)

出典: [Loop Engineering](https://zenn.dev/ino_h/articles/2026-06-16-loop-engineering-goal)

「毎ターン人間がプロンプトを打つ」のをやめ、完了条件を 1 度だけ書いてエージェントを
自走させる考え方。記事が挙げる 5 要素と、このリポジトリでの対応は次のとおり。

| 記事の要素 | crystal での対応 |
|---|---|
| Automations(定期実行による発見と分類) | 組み込みの `/schedule` に委ねる。回し方は [トリガー](#トリガー) を参照 |
| Worktrees(並行エージェントの隔離) | **組み込みの `EnterWorktree` に委ねる**。本 plugin では実装しない |
| Skills(プロジェクト固有の作業知識) | `skills/` 11 個 + `rules/`(SessionStart hook が全セッションに注入) |
| Plugins / Connectors(外部ツール接続) | 本リポジトリ自体が plugin。MCP 接続は各プロジェクト側の設定に任せる |
| Sub-agents(実装者と検証者の分離) | `crystal:verifier` / `crystal:spec-critic`、および `subagent-gate.sh` |
| 外部メモリ(実行間で状態を失わない) | `.claude/goal.md` の `## 判定履歴` / `docs/spec/` / `.claude/learnings.md`(SessionStart hook が自動注入) / `evals/` |

ループ本体は Stop hook `goal-gate.sh`。`/crystal:goal` で完了条件を `.claude/goal.md` に
定義すると(`docs/spec/` に approved な仕様があれば受け入れ条件を自動インポート)、
応答完了のたびに Haiku で達成判定し、未達なら exit 2 で差し戻す。

- **オプトイン**: `.claude/goal.md` が `status: active` のときだけ動く。それ以外はコストゼロ
- **毎ターン判定**: stop-gate と異なり `stop_hook_active` で素通ししない(意図的な設計差)。
  無限ループ防止は round カウンタ + `max_rounds`(テンプレート既定 5、超過で `status: stalled`)が担う。
  `/crystal:goal` は作業規模に応じて値を提案する
- **判定は 2 段階**: まず goal-gate が完了条件に併記された検証コマンドを**実際に実行する**。
  1 つでも失敗したら Haiku を呼ばずにその場で差し戻す(そのラウンドの judge コストを払わない)。
  全て通れば、実測結果を添えて Haiku が最終判定する。
  記事の「機械が真偽を判定できる終了状態」をテキスト判定に落とさないための仕組み
- **実行できるコマンドは「全体一致」で限定される**: この実行は Claude Code の Bash ツールを
  通らないため、権限プロンプトも PreToolUse(`pre-bash-guard.sh`)もかからない。
  したがって許可はコマンド**全体**が既定パターンのどれかに完全一致する場合だけとする:
  `npm|pnpm|yarn|bun test` / `… run <script>` / `npx vitest run` / `pytest [-q]` /
  `tsc --noEmit` / `go test ./...` / `cargo test|check|clippy` / `make test|check|lint` /
  `mvn|gradle test|verify|check` / `git status --porcelain` など。
  **コマンド名の先頭トークンだけで許可してはいけない**: `node` / `python` / `git` / `make` /
  `go` / `cargo` / `npx` は引数だけで任意コードを実行できる汎用ランナーであり、
  `node -e '…'`、`git -c alias.x='!…' x`、`make -f evil.mk`、`npx -y <pkg>` が
  区切り文字もメタ文字も使わずに素通りする(実際にこの穴を作り込み、レビューで検出した)。
  一致しなかったコマンドは差し戻さず、従来どおり judge の読解に委ねる
- **goal.md が git 管理下なら実行しない**: リポジトリを clone しただけで
  `.claude/goal.md` のコマンドが走るのを防ぐための境界。
  `.claude/goal.md` は `.gitignore` に入れる前提の運用なので、通常は影響しない
- **stop-gate はゴール中も毎ターン走る**: 同じ `npm test` が 2 度走ることはあるが、
  条件付きで無効化してはいけない。goal-gate が実際に実行するのは
  「## 完了条件」内かつ許可パターンに一致したコマンドだけで、その判定を stop-gate 側で
  正確に再現できない。両者の条件がずれると「stop-gate は goal-gate に任せたつもり、
  goal-gate は judge に任せたつもり」で実検証が 1 つも走らないゴールが生まれる
- **judge は会話の出力しか読めない**: コマンドを実行することもファイルを読むこともできない。
  そのため完了条件は `<終了状態> — 検証: <コマンド> が <期待結果>` の形で書き、
  実測結果にも作業ログにも現れていない条件は未達として扱われる。
  アプリコードを変更したのにテストの追加・更新と実行結果が無い場合も未達になる
  (ドキュメント/設定のみの変更と、既存テストで担保されるリファクタは除く)
- **fail-open**: claude CLI 不在・認証失敗・出力パース失敗時は判定をスキップして通す
- 判定結果は `~/.claude/logs/goal-gate.jsonl` と `.claude/goal.md` の `## 判定履歴`(直近 5 件)に残る。
  後者は次ターン以降も読まれる外部メモリとして機能する
- `.claude/goal.md` は `.gitignore` に追加すること(untracked のままだと stop-gate の
  「変更なし判定」を汚染する)。`/crystal:goal` が追加を提案する

## plan / spec / goal / loop の使い分け

| | 起動トリガー | 停止条件 | 判定者 | 状態の置き場 |
|---|---|---|---|---|
| plan mode(組み込み) | 人が plan mode に入る | 人がプランを承認する | 人 | セッション内(揮発する) |
| `/crystal:spec` | 人が叩く | 人が `ステータス: approved` にする | 人(+ `crystal:spec-critic`) | `docs/spec/*.md` |
| `/crystal:goal` | 人が 1 回叩く → 以降はターン終了ごとに自動 | 完了条件をすべて満たす / `max_rounds` 超過 | 検証コマンドの exit code → Haiku(goal-gate) | `.claude/goal.md` |
| `/loop`(組み込み) | 時間間隔 | 人が止める | 判定しない | 残らない |

判断基準:

- **終わりが定義できる** → `goal`
- **定期的に見張るだけで終わりが無い** → `loop`
- **完了条件を機械判定できない** → まだ `plan` か `spec` の段階。goal にしてはいけない
- **来週も使う条件** → `spec` に書いて goal にインポートする(その場限りなら goal に直接書く)

## 標準の開発フロー

```
/crystal:spec <機能>   要件を詰める → 承認したら ステータス: approved に昇格
/crystal:goal          AC → DC、spec の制約 → goal の制約 に変換し、そのまま実装開始
  ↓ 以降は自走 (goal-gate が毎ターン判定 → 未達なら差し戻し)
status: done           達成
/crystal:learn         知見を learnings.md / evals/ に落とす (ここだけ人が叩く)
```

## ガードレール

記事が「常態として向き合うべき本番問題」として挙げる 3 つへの対策:

| リスク | 対策 |
|---|---|
| 無限ループ | `max_rounds`(テンプレート既定 5)。判定前に round を進めて永続化し、超過したら `status: stalled` にして自動判定を止める。ランタイム側も同一ターンの連続ブロックを既定 8 回で打ち切る(`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`)ため、`max_rounds` は 8 以下にする |
| ゴールドリフト | `.claude/goal.md` の `## 制約`。judge が `violations` を返したら、完了条件を満たしていても `met` を false に強制して差し戻す |
| コスト爆発 | judge は Haiku 固定。検証コマンドが失敗したラウンドは judge を呼ばない(未達が機械的に確定しているため)。`--output-format json` の `total_cost_usd` を frontmatter の `cost_usd` に累積し、`/crystal:goal status` で確認できる |

## トリガー

記事はループの最小要件を「**トリガー**(起動条件)と**検証可能なゴール**(終了状態)」としている。
goal-gate が担うのは後者だけで、前者は起動方法の選択になる。

| トリガー | 起動方法 | 用途 | 注意 |
|---|---|---|---|
| 手動(既定) | `/crystal:goal` を叩く | 対話しながら回す | — |
| 非対話 1 ショット | `claude -p "ゴールを達成するまで作業を続けて"` | CI・手元バッチ | 人が止められない。`max_rounds` を先に見直す |
| 定期 | 組み込みの `/schedule` から上の `claude -p` を起動する | 記事の Automations 相当(発見と分類を自動で回す) | セッションごとにゴールを作り直す設計にする |

どのトリガーでも Stop hook は発火するため、専用のループスクリプトは要らない。
`.claude/goal.md` が `status: active` なら goal-gate がそのまま効き、未達なら差し戻され、
達成(`status: done`)または `max_rounds` 超過(`status: stalled`)で終了する。

非対話で回す前に確認すること:

- **すべての DC の検証コマンドが実行可能な形か**。許可リスト外・リダイレクト付きだと
  機械判定が効かず、人が見ていない場所で Haiku の読解だけが判定根拠になる
- **`max_rounds` は対話時より小さくする**。差し戻し 1 回ごとにフルターンを消費する

> **`/loop` と goal を同時に使わないこと。** 時間トリガー(loop)とターン終了トリガー(goal-gate)が
> 同一セッションで二重ループになり、loop の 1 周ごとに goal-gate が差し戻しを重ねる。
> `/schedule` は別セッションを起こすため二重にならない。定期実行はこちらを使う。

## 並行エージェント実行時の検証

サブエージェントを並列で走らせるとき、検証をどの層で走らせるかを分けている。

| 検証の粒度 | 走らせる場所 | 理由 |
|---|---|---|
| ファイル単位の lint / 整形 | `PostToolUse`(`lint-changed.sh` / `format-on-save.sh`) | サブエージェント内でも発火するため、変更した本人がその場で直せる |
| 完了報告の裏取り | `SubagentStop`(`subagent-gate.sh`) | 変更したうえで「テストが通った」と主張しているのに実行痕跡が無いものだけを止める。安く済む |
| プロジェクト全体の typecheck / test | 親の `Stop`(`stop-gate.sh`)に一本化 | 並列エージェントは既定で worktree 隔離されず同一チェックアウトを共有する。同時にフルテストを走らせるとキャッシュ破壊と CPU 飽和を招く |

`subagent-gate.sh` の挙動:

- 対象は「テスト / lint / 型チェック / ビルドが通った」旨を述べている完了報告のみ。
  それ以外は素通しする
- **ファイルを 1 つも変更していないエージェントは対象外**。判定は正規表現なので、
  一人称の完了報告と他人のコードについての説明文を区別できない
  (「stop-gate.sh はテスト・型チェック・lint を実行し、通っていれば素通しする」は一致する)。
  裏取りが要るのは変更した本人だけなので、transcript に `Write` / `Edit` / `MultiEdit` が
  無ければ素通しする。調査エージェントの報告が丸ごと自己訂正文に置き換わるのを防ぐ
- `agent_transcript_path` の Bash 実行履歴に対応する検証コマンドが無ければ exit 2 で差し戻し、
  「実際に実行して出力を示す」か「未検証と明記して報告を訂正する」かを選ばせる
- `stop_hook_active: true`(差し戻し後の再停止)は素通しする
- fail-open。ログは `~/.claude/logs/subagent-gate.jsonl`

## Eval Engineering

プロジェクトの `evals/cases/*.md`(1ケース1ファイル、git で版管理)に検証ケースを蓄積し、
プラグイン同梱の `scripts/eval-run.sh` で実行する。形式は `templates/eval-case.md` を参照。

- **command 型**: コマンド実行 + exit code / 出力正規表現で機械検証(優先)
- **rubric 型**: Haiku がルーブリックに照らして判定(主観評価のみ。CLI 不在時は SKIP)
- 操作は `/crystal:eval`(add / run / list)。FAIL が 1 件でもあれば exit 1
- `/crystal:learn` は 2 回以上再発した問題の eval ケース化を提案する
- `crystal:verifier` は `evals/` があればランナーを実行し判定材料に含める

## 更新

リポジトリを編集したら、次の手順で反映する。注意点が 2 つある:

- マーケットプレイス `yuki` のソースは **GitHub の `YukiTominaga/claude-toolbox`**
  (ローカルディレクトリではない)。**push するまでローカルの編集は一切反映されない**
- **marketplace update だけではインストール済みプラグイン(キャッシュコピー)は更新されない**

```bash
# 1. plugin.json と marketplace.json の version をバンプする(両方揃えること。
#    plugin update はバージョン番号で新旧を判定する)
# 2. commit して push する(marketplace のソースが GitHub のため必須)
git push
# 3. marketplace のメタデータを更新
claude plugin marketplace update yuki
# 4. インストール済みプラグイン本体を更新
claude plugin update crystal@yuki
# 5. 新しいセッションを開いて反映
```

## 開発

```bash
npm install
npm test
```

vitest で `goal-gate.sh` / `stop-gate.sh` / `subagent-gate.sh` / `session-learnings.sh` の
振る舞いをテストしている。ゲートは fail-open 設計(異常時は黙って exit 0)なので、
壊れても手動 E2E では気づけない。`tests/helpers/sandbox.ts` が使い捨ての git リポジトリを作り、
`claude`(judge)と `npm`(DC の検証コマンド)を fake に差し替えて実行する。

## 構成

- `.claude-plugin/plugin.json` — plugin マニフェスト(`name: crystal`)
- `.claude-plugin/marketplace.json` — マーケットプレイス定義(`name: yuki`)
- `hooks/hooks.json` — hooks 登録。コマンドは `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` を参照する

## 前提

- hooks は `node` / `jq` が PATH にあることを前提とする。
- goal-gate と eval の rubric 判定は `claude` CLI が PATH にあり認証済みであることを
  前提とする。満たさない場合は判定をスキップする(fail-open)。
- goal-gate は完了条件の検証コマンドを実行するため、`hooks.json` での timeout を
  600 秒にしてある(テスト実行時間がそのまま判定時間に乗るため)。
  検証は全体で 240 秒・1 本あたり 120 秒の予算で打ち切り、残りは「未実行」として judge に渡す。
  予算を持たせないと、round を消費したまま hook がランタイムに打ち切られ、
  判定が 1 度も記録されないまま `max_rounds` に達して `stalled` に落ちる。
- `timeout`(coreutils)が無い環境(macOS の既定)でも動くよう、goal-gate と `eval-run.sh` は
  `perl -e 'alarm shift; exec @ARGV'` によるタイムアウトで代替する。従来は `timeout` に
  依存していたため、macOS では judge が exit 127 で必ず失敗し、判定に到達できなかった。
- `rules/` は SessionStart hook(`session-rules.sh`)が注入するため、プラグインを
  有効化するだけで適用される。外部の CLAUDE.md からの参照は不要。
- プロジェクトの `.claude/learnings.md` も SessionStart hook(`session-learnings.sh`)が
  注入する。`/crystal:learn` と `rules/learning.md` は知見をこのファイルに書き溜めるが、
  読み込む導線が無いと次のセッションで参照されない(書くだけで回収されない)ため。
  際限なく増えるので末尾 8000 バイトまでを載せ、エントリの途中で切らないよう
  見出し行から始める。切り詰めた場合はその旨を明記する。
- `audit-config.sh` は手動実行用スクリプトで、`hooks.json` には登録していない。
