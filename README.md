# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個 |
| `agents/` | `spec-critic`, `verifier` |
| `commands/` | `/learn`, `/spec`, `/goal`, `/eval`, `/adr` |
| `hooks/` | `hooks.json` + スクリプト 10 本(破壊コマンドガード / format-on-save / lint / bash ログ / stop-gate / goal-gate / subagent-gate / session-rules / session-learnings / audit-config) |
| `scripts/` | 手動実行系スクリプト(`eval-run.sh`) |
| `rules/` | テスト方針など(SessionStart hook `session-rules.sh` が全セッションに自動注入)。**hook で強制できることは書かない**方針 — [rules/ の方針](#rules-の方針) を参照 |
| `templates/` | spec / goal / eval-case / adr テンプレート |

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、`~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール

```bash
claude plugin marketplace add YukiTominaga/claude-toolbox
claude plugin install crystal@yuki --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn` / `crystal:goal` / `crystal:eval` / `crystal:adr`
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
| Sub-agents(実装者と検証者の分離) | 常時は `subagent-gate.sh` / `stop-gate.sh`(hook)。`crystal:verifier` / `crystal:spec-critic` は**明示呼び出し時のみ** |
| 外部メモリ(実行間で状態を失わない) | `.claude/goal.md` の `## 判定履歴` / `docs/spec/` / `.claude/learnings.md`(SessionStart hook が自動注入) / `.claude/decisions.md` → `docs/adr/` / `evals/` |

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
  `npm|pnpm|yarn|bun test` / `… run <script>` / `npx vitest run` / `pytest [-qxvs]` /
  `tsc --noEmit` / `ruff check|mypy|eslint|shellcheck <path>` / `go test|vet ./...` /
  `cargo test|check|clippy` / `make test|check|lint` / `mvn|gradle test|verify|check` /
  `git status --porcelain|diff --exit-code|diff --quiet` など
  (全体は `hooks/goal-gate.sh` の `VERIFY_RE` が正)。
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

いずれも「これから何を作るか」を扱う。**既に決めたことの理由**は別軸で、
`.claude/decisions.md` → `/crystal:adr` → `docs/adr/` が担当する([ADR](#adr-意思決定の記録))。

## 標準の開発フロー

```
/crystal:spec <機能>   要件を詰める → 承認したら ステータス: approved に昇格
/crystal:goal          AC → DC、spec の制約 → goal の制約 に変換し、そのまま実装開始
  ↓ 以降は自走 (goal-gate が毎ターン判定 → 未達なら差し戻し)
status: done           達成
/crystal:learn         知見を learnings.md / evals/ に落とす (ここだけ人が叩く)
/crystal:adr <テーマ>  「なぜこの構成にしたか」を docs/adr/ に残す (決定をした回だけ)
```

作業中に決定をしたら、その場で `.claude/decisions.md` に書き残る(`rules/decision-log.md`)。
`/crystal:adr` はそれを一次情報として読む。詳細は [ADR](#adr-意思決定の記録) を参照。

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
| 仕様(AC)単位の独立判定 | `crystal:verifier`(**明示呼び出し時のみ**) | 会話の文脈を持たない第三者判定。日常の完了報告で自動起動すると stop-gate / goal-gate と合わせてテストが三重に走る |

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

## ADR (意思決定の記録)

出典: [ADR 作成を Claude の Agent Skills で自動化する](https://blog.cybozu.io/entry/2026/07/28/090000)

「なぜこの構成にしたのか」「他にどんな選択肢があって、なぜ採らなかったのか」を
`docs/adr/NNNN-<slug>.md` に 1 決定 1 ファイルで残す。形式は `templates/adr.md`。

記事が挙げる課題と、このリポジトリでの対応:

| 記事の課題 | crystal での対応 |
|---|---|
| ADR 作成が後回しになり、書く頃には記憶が薄れている | `rules/decision-log.md` が**決定した瞬間に** `.claude/decisions.md` へ書かせる。ADR はそれを読んで後から起こす |
| 材料が作業ログ・仕様書・実装コードに散らばっている | `/crystal:adr` の「1. 情報収集」が `decisions.md` / `docs/spec/` / `learnings.md` / `goal.md` の判定履歴 / `git log` / 実装を横断して集める |
| いきなり全文を書くと方向がずれて手戻りが大きい | 「3. 内容確認」を**必須の合意チェックポイント**にし、項目ごとの骨子で合意してから清書する |
| 過去 ADR と文体が揃わない | 「4. 清書」で既存 `docs/adr/*.md` を読み、文体・粒度を合わせる |

記事が「鍵になる」としているのは skill ではなく**一次情報(作業ログ)が残っている文化**の方で、
crystal に欠けていたのもそこだった。`.claude/learnings.md`(ハマりポイント)、`docs/spec/`
(これから作るものの要件)、`goal.md` の判定履歴(未達の記録)はあったが、
**採らなかった案とその理由**を残す場所がどこにも無く、決定の「なぜ」は毎回セッションと
一緒に消えていた。`.claude/decisions.md` はその穴を埋める層で、
散文で構わない代わりに**却下案と却下理由を必ず含める**ことだけを要求する。

設計上の判断:

- **`decisions.md` は SessionStart で注入しない**。`learnings.md` は「同じ問題を繰り返さない」
  ために毎セッション読まれる必要があるが、決定ログの読み手は `/crystal:adr` だけで、
  全セッションに載せてもコンテキストを食うだけになる。回収経路は
  `/crystal:adr` の情報収集フェーズで閉じている
- **hook で強制しない**。何が「後から理由を問われる決定」かは機械判定できず、
  誤検知したゲートは決定でないものを書かせて `decisions.md` を薄める。
  [rules/ の方針](#rules-の方針) の裏返しで、hook で強制できないものは rules に置く
- **決定を変えるときは書き換えず `supersede`**。旧 ADR はステータス行だけを
  `superseded by ADR-NNNN` に書き換え、本文は残す。上書きすると
  「なぜ変えたか」が消え、ADR の存在価値そのものが失われる
- **`decisions.md` は commit する**。`learnings.md` と同じチーム資産で、1 台の手元にしか
  無い決定ログはチームの ADR を支えられない。`goal.md` を `.gitignore` に入れるのは
  goal-gate がそこに書かれたコマンドを**実行する**ためで、何も実行しない
  `decisions.md` には当てはまらない。untracked のまま放置するのだけが誤りで、
  stop-gate の「変更なし判定」を汚す
- **`decisions.md` は追記のみ・全文ロードしない**。`learnings.md` と同じく際限なく増えるが、
  読み手が `/crystal:adr` だけなので注入側ではなく**読む側**で絞る。テーマで見出しを
  絞り込み、ADR 化済み(`→ ADR-NNNN` マーカー付き)は飛ばし、32KB を超えたら
  `.claude/decisions/YYYY.md` へ年分割する
- **`goal-gate.jsonl` は `cwd` で絞ってから読む**。このログは `$HOME` 配下に
  プロジェクト横断で積まれる。ADR は恒久文書なので、他プロジェクトの差し戻し理由が
  却下理由として紛れ込むと後から出所を辿れない。`cwd` は goal-gate が全レコードに
  記録する(回帰テストあり)。`/crystal:learn` の再発回数カウントも同じ理由で絞る
- **裏が取れない項目は空けて出す**。記事も「記憶が薄れる問題は完全には解消されない」と
  している。特に却下理由は記録に残りにくく最も捏造しやすいため、
  `/crystal:adr` には材料が無い項目を「材料なし」と明示させ、
  もっともらしい理由で埋めることを禁じてある。誤った ADR は無い ADR より害が大きい

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
- `.claude/decisions.md` は SessionStart で注入しない(読み手が `/crystal:adr` に限られるため)。
  `learnings.md` との違いは [ADR](#adr-意思決定の記録) を参照。

## rules/ の方針

プラグインには native な `rules/` コンポーネントが無い(公式のコンポーネントは
skills / agents / hooks / MCP / LSP / monitors)。そのため `session-rules.sh` で
`SessionStart` の `additionalContext` として注入しているが、この経路には
`.claude/rules/` のような `paths:` フロントマターによるスコープ限定が無く、
**全ファイルが毎セッション無条件で入る**。CLAUDE.md 以上に選別が要る。

採用基準は 2 つ:

1. **hook で強制できることは rules に書かない。** `stop-gate.sh` が実際にテスト・
   型チェック・lint を実行して exit 2 で差し戻す以上、「完了と報告する前に検証しろ」
   と散文で書いても遵守率は上がらず、コンテキストを消費するだけ。
   [Opus 5 のプロンプティングガイド](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)
   も、旧世代向けの検証指示("include a final verification step" 等)は
   過剰検証を招くレガシー足場として削除を推奨している。
2. **既定の挙動と一致することは書かない。** 「シンプルに書く」「secret を
   ハードコードしない」「push は言われた時だけ」といった一般論は、書いても
   振る舞いが変わらない。残すのは既定と**異なる**規約
   (Conventional Commits の型指定、`main` に直接コミットしない、
   2 つ目のテストフレームワークを入れない、等)に限る。

判定は「この行を消したら Claude が間違えるか?」で行い、答えが No なら消す。
