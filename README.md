# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個 |
| `agents/` | `spec-critic`, `verifier` |
| `commands/` | `/learn`, `/spec`, `/goal`, `/eval`, `/loop` |
| `hooks/` | `hooks.json` + スクリプト 8 本(破壊コマンドガード / format-on-save / lint / bash ログ / stop-gate / goal-gate / auto-commit / session-rules) |
| `scripts/` | 手動実行系スクリプト(`eval-run.sh`, `loop-add.sh`, `loop-next.sh`, `loop-guard.sh`, `loop-log.sh`) |
| `rules/` | コーディング規約・テスト方針・検証ラダーなど(SessionStart hook `session-rules.sh` が全セッションに自動注入) |
| `templates/` | spec / goal / eval-case / loop / backlog テンプレート |
| `evals/` | このリポジトリ自身の eval ケース(`scripts/eval-run.sh` で実行) |

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、`~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール(ローカル)

```bash
claude plugin marketplace add ~/claude-toolbox
claude plugin install crystal@yuki-local --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn` / `crystal:goal` / `crystal:eval` / `crystal:loop`
- サブエージェント: `crystal:spec-critic` / `crystal:verifier`
- スキル 11 個は `crystal` 由来でロード
- hooks(SessionStart/PreToolUse/PostToolUse/Stop)が自動登録され、
  `rules/*.md` はセッション開始時に自動でコンテキストへ注入される

## Loop Engineering

「プロンプトを1回ずつ書く」のではなく「エージェントが回るループを設計する」ための構成。
crystal はループを **外側**(仕事を見つけて渡す)と **内側**(完了まで反復する)に分けている。

```
入口 (/crystal:loop add)   やりたいこと → 分解 or 仕様化 → 承認 → キューに積む
外側 (/crystal:loop next)  discover → 仕様 → ゴール定義 → [内側] → 独立検証 → 台帳 → 次へ
内側 (goal-gate hook)                          実装 ⇄ 達成判定 を完了条件を満たすまで反復
```

### 作業の入口

**やりたいことは `/crystal:loop add` に渡す。これが唯一の入口**。1 件だけ今すぐやる場合も
キューを経由させる(入口を分けると、やった仕事が台帳に残らない穴ができるため)。
`add` は積んだあと「続けて `next` を回すか」を確認するので、そのまま実装まで進める。

```bash
/crystal:loop add 認証まわりを Identity Platform に寄せたい。現状 NextAuth で
握っているセッションを Firebase Admin SDK のセッションクッキーに置き換える。
requireRole は残す。Cloud Run の ADC 設定も含めて。
```

入力が「やりたいことの記述」なら**単独で完了判定できる粒度**に分解して N 行を積み、
「手段まで書かれた計画」なら**行に刻まず `docs/spec/` に変換して 1 行だけ**積む。
この振り分けはコマンド側で行うので、使い分けを覚える必要はない。

**計画(plan mode の出力)を行に刻まない理由**: 計画は書いた時点のコード状態に対する
実装手段を含む。キューの項目は数日後や無人ループに拾われるため、具体的であるほど
**陳腐化した手段を忠実に実装してしまう**。また計画の章立ては説明の順序であって
検証可能な増分の順序ではないため、節に沿って割ると内側ループが判定できない項目が並ぶ。

plan mode 自体は併用してよい(未知のコードを探索しながら方針を決める用途では有効)。
ただしその**出力**は実装の入力にせず、`/crystal:loop add` 経由で仕様に変換する。

| 構成要素 | crystal での実装 |
|---|---|
| automations(周期実行) | 対話中は組み込みの `/loop 30m /crystal:loop next`。無人は cron / launchd から `scripts/loop-run.sh` |
| worktrees(並列隔離) | **組み込みに委譲**。`LOOP.md` の契約から参照するだけ |
| skills(プロジェクト知識) | `skills/` の 11 個 + `rules/` の自動注入 |
| connectors(MCP) | **既存の接続に委譲**。`/crystal:loop refill` は GitHub MCP を使う |
| subagents(独立した検証者) | `crystal:verifier`(生成者と別コンテキストで実際にコマンドを実行) |

### 構成要素の詳細

- **ループ契約 `LOOP.md`**: トリガー / スコープ / 発見源 / 検証 / 停止条件 / ゲート の 6 節。
  `/crystal:loop init` が `templates/loop.md` から生成する
- **発見源 (discover)**: `docs/backlog.md`(1行1項目のチェックリスト)。
  `scripts/loop-next.sh` が先頭の未着手項目を 1 件だけ返す(枯渇時は exit 3)。
  追記は `scripts/loop-add.sh` が採番するので、行を手で書かない。
  GitHub Issues は `/crystal:loop refill` で backlog に取り込む
- **予算と暴走の歯止め**: `scripts/loop-guard.sh` が実行前に判定し、**通過したらゲート自身が
  台帳に記録する**(消費をエージェントの自己申告に依存させない。途中で失敗しても開始の事実は残る)。
  状態を見るだけの `--check` は記録しない。

  | `LOOP.md` の設定 | 役割 |
  |---|---|
  | `max_runs_per_day` | 1 日に回してよい回数 |
  | `max_minutes_per_run` | 1 イテレーションの壁時計時間(goal-gate が停止条件として効かせる) |
  | `max_turns_per_run` | 暴走の歯止め。`loop-run.sh` が `--max-turns` として渡す |
  | `max_cost_usd_per_day` | 実費の上限。**サブスクリプションでは空のままにする**(下記) |

  **金額を歯止めにしない**。サブスクリプション(Max 等)では `total_cost_usd` はトークン数から
  計算した参考値にすぎず追加課金も発生しないので、金額で止めても意味を持たない。
  実費が本当に発生する API キー運用や CI に持っていくときだけ `max_cost_usd_per_day` を設定する。
  **記録は常に続ける** — 1 イテレーションの重さを測る相対指標として使える
  (実測で 1 回 $1.7〜$3.3 相当。決して軽くない)
- **作業ブランチ**: `next` は項目ごとに `loop/<id>` ブランチを作って作業する。
  `main` のままだと `main` 直接コミット禁止と auto-commit の main スキップが重なり、
  **作業が一切コミットされない**ため
- **台帳 (record)**: `.claude/loop/run-log.jsonl`。書き込みは必ず `scripts/loop-log.sh` 経由。
  クラッシュやコンテキストのリセットを跨いで「何を回したか」が残る
- **検証ラダー**: `rules/verification.md` に L1(決定的)〜 L5(人間)を定義。
  タスクが許す限り低いレベルに留め、検証者は生成者から独立させる

### 記録先の使い分け

ループが書き残すものは 4 つのストアに分かれている。**同じことを 2 か所に書かない**。
迷ったら「それ単体で着手できるか」で判定する — できるなら仕事(backlog)か知見(learnings)、
できないなら発見(signals)。

| ストア | 答える問い | 書く | 読む | git |
|---|---|---|---|---|
| `docs/backlog.md` | 何を、どの順でやるか | `scripts/loop-add.sh` | `scripts/loop-next.sh`(機械) | ✓ |
| `docs/signals/` | 何に気づいたか(未処理) | `scripts/signal-add.sh` | `/crystal:loop next`(キュー枯渇時)、`/crystal:learn` | ✓ |
| `.claude/learnings.md` | 確定した再利用可能な知見 | `/crystal:learn` | 人・将来のセッション | ✓ |
| `.claude/loop/run-log.jsonl` | 何を回したか(実行の事実) | `scripts/loop-guard.sh` / `scripts/loop-log.sh` | `/crystal:loop next` の冒頭(手順 0) | ✗ ローカル |

signals と learnings は重複ではなく**ライフサイクルの段階が違う**。signal は「未処理の発見」、
learnings は「処理を終えて再利用可能になった知見」で、signal が知見になったら本文を
learnings に書き、その signal を `status: learned` にする。

### backlog と spec の使い分け

**backlog は「やる」の管理、spec は「終わった」の定義**。寿命と粒度が違うので併存する。

| | `docs/backlog.md` | `docs/spec/<name>.md` |
|---|---|---|
| 答える問い | **何を、どの順でやるか** | **1件について、どこまでやったら完了か** |
| 粒度 | 1 行 × N 件 | 段落 × 1 件 |
| 変化するもの | 順序と 未着手/完了 | 承認後は原則変えない |
| 主な読み手 | `loop-next.sh`(機械) | 実装者と `crystal:verifier` |
| 無いと困ること | ループが次の仕事を見つけられない | verifier が完了を判定できない |

```
backlog の1行 ──(取り出す)──> spec(境界と AC-* を固める)
                                 └─> goal.md の DC-* ─> 内側ループ ─> verifier
```

- **全項目に spec は要らない**。受け入れ条件が 1〜2 行で自明なもの(typo 修正・依存更新)は
  spec を省き、`.claude/goal.md` の `DC-*` を直接書く
- 逆に 1 つの変更を N 件に分解した場合、その N 件は**1 つの spec を共有**する
  (スコープの「含まない」は変更全体に対してしか定義できないため)。各行の `spec:` で同じパスを指す
- `/crystal:spec` は単体でも使えるが、通常の導線では `/crystal:loop add` と
  `/crystal:loop next` が内部で呼ぶ

`.claude/loop/` は `.gitignore` に追加すること(`/crystal:loop init` が提案する)。

### 無人実行

`scripts/loop-run.sh` が 1 イテレーションを無人で回す。`claude -p "/crystal:loop next"` を
**新しいプロセスで**起動する。理由は 2 つある:

- プラグインはキャッシュへの実コピーで、hooks はセッション開始時に固定される。
  **同じセッション内でループの改修をドッグフーディングすることは原理的にできない**
- cloud の Routines はローカルのリポジトリにも MCP にも触れない。ローカルリポジトリを
  触るループの無人化は、cron / launchd + `claude -p` が現実的な形になる

`CRYSTAL_UNATTENDED=1` が立ち、次の 2 つが変わる:

- `pre-bash-guard` が `LOOP.md` のゲートに当たる操作(PR の作成・マージ、依存の追加、
  force push)を `deny` する。**無人では承認を待てないので、ゲートは「聞く」ではなく
  「やらない」として実装する**
- キューが枯れても signal を backlog に勝手に昇格させない(仕事を自分で作らない)

登録は人が行う(これ自体がゲート)。例:

```bash
# 平日 9 時に 1 イテレーション
0 9 * * 1-5 cd /path/to/repo && CLAUDE_PROJECT_DIR=$(pwd) ./scripts/loop-run.sh >> .claude/loop/cron.log 2>&1
```

## ゴール達成自動判定 (goal-gate)

`/crystal:goal` で完了条件を `.claude/goal.md` に定義すると(`docs/spec/` に approved な
仕様があれば受け入れ条件を自動インポート)、応答完了のたびに Stop hook `goal-gate.sh` が
Haiku で達成判定し、未達なら差し戻す。

- **オプトイン**: `.claude/goal.md` が `status: active` のときだけ動く。それ以外はコストゼロ
- **毎ターン判定**: stop-gate と異なり `stop_hook_active` で素通ししない(意図的な設計差)。
  暴走防止は下記の停止条件 4 層が担う
- **停止条件は 4 層**(単独の層に頼らない):

  | 層 | 条件 | 結果 |
  |---|---|---|
  | 1. 達成 | 完了条件をすべて満たしたと判定 | `status: done` |
  | 2. 反復上限 | `round > max_rounds`(既定 5) | `status: stalled` |
  | 3. 予算 | 開始からの経過が `max_minutes`(既定 60)超 | `status: stalled` |
  | 4. 無進捗 | 差分が変わらないラウンドが `max_no_progress`(既定 2)回連続 | `status: stalled` |

  無進捗のラウンドでは判定器を呼ばずに差し戻すため、止まっている間の課金も抑えられる。
  `started_epoch` / `last_sig` は hook が自動で埋めるので手動で編集しない
- **判定器の前に L1 検証**: 停止条件を抜けたあと、判定器 (L4) を呼ぶ前に
  `scripts/project-checks.sh`(typecheck / lint / test)を**毎ラウンド無条件で**実行し、
  赤なら判定器を呼ばずに差し戻す。検証ラダーの安い順に並べるため、かつ
  `stop_hook_active` で素通しする stop-gate では内側ループの L1 が抜けるため
- **fail-open**: claude CLI 不在・認証失敗・出力パース失敗時は判定をスキップして通す。
  ただし L1 検証は `command -v claude` より手前にあるので、CLI が無くても効く
- 判定履歴は `.claude/loop/judge-log.jsonl` に残る(/learn の素材、台帳と同じ場所)
- `.claude/goal.md` は `.gitignore` に追加すること(untracked のままだと stop-gate の
  「変更なし判定」を汚染する)。`/crystal:goal` が追加を提案する

## 作業中の変更を自動コミット (auto-commit)

「気づいたら未コミット」を無くすための Stop hook。応答が素直に終わったとき、
その時点の変更を feature ブランチに 1 コミットとして落とす。**設定不要で全リポジトリに効く**。

- **動かない場面**(いずれも無条件でスキップ):
  `main` / `master` / detached HEAD、rebase・merge・cherry-pick・revert・bisect の途中、
  git 管理下でない場合、変更が無い場合
- **差し戻しの往復中(`stop_hook_active`)もコミットする**。goal-gate が回す内側ループは
  毎ラウンド差し戻すため、ここで素通しすると done 判定のラウンドまで含めて一度も
  コミットされず、無人実行では成果がまるごと失われる。
  ただし往復中はメッセージ生成の Haiku を呼ばず、定型メッセージにフォールバックする
- **未追跡ファイルも含める**(`git add -A` 相当)。新規作成したファイルこそ取りこぼしやすいため。
  これは `rules/git-workflow.md` の一括 add 禁止に対する**明示的な例外**として同ファイルに記載している
- **機密パスの検出で中止**: `.env` / `*.pem` / `*.key` / `id_rsa` / `credentials` / `.ssh/` /
  `.aws/` などに一致するパスが対象に入っていたらコミットせず、`systemMessage` で知らせる。
  `.gitignore` に追加すれば通常どおり動く
- **コミットメッセージは Haiku が差分から生成**する(Conventional Commits 形式)。
  CLI 不在・失敗時は `chore: 自動コミット (N files: ...)` にフォールバックして必ずコミットする
- 生成されるのは作業途中のコミットなので、レビュー前に `--amend` や squash で整えることを前提とする

## Eval Engineering

プロジェクトの `evals/cases/*.md`(1ケース1ファイル、git で版管理)に検証ケースを蓄積し、
`scripts/eval-run.sh` で実行する。形式は `templates/eval-case.md` を参照。

- **command 型**: コマンド実行 + exit code / 出力正規表現で機械検証(優先)
- **rubric 型**: Haiku がルーブリックに照らして判定(主観評価のみ。CLI 不在時は SKIP)
- 操作は `/crystal:eval`(add / run / list)。FAIL が 1 件でもあれば exit 1
- `/crystal:learn` は 2 回以上再発した問題の eval ケース化を提案する
- `crystal:verifier` は `evals/` があればランナーを実行し判定材料に含める

本リポジトリ自身も `evals/cases/` を持つ(loop スクリプト・hook の相互作用・
スクリプトの構文・マニフェストの JSON 妥当性)。シナリオ本体は 2 つに分かれており、
loop スクリプトは `evals/bin/loop-cases.sh`、hooks は `evals/bin/hook-cases.sh` にある。
どちらも一時ディレクトリに最小プロジェクトを作り、`claude` と `npm` をスタブに
差し替えて(課金せず決定的に)検証する。編集したら次を実行する:

```bash
CLAUDE_PROJECT_DIR=$(pwd) ./scripts/eval-run.sh
```

## 更新

リポジトリを編集したら、次の手順で反映する。**marketplace update だけでは
インストール済みプラグイン(キャッシュコピー)は更新されない**ことに注意:

```bash
# 1. plugin.json の version をバンプする(plugin update はバージョン番号で新旧を判定する)
# 2. marketplace のメタデータを更新
claude plugin marketplace update yuki-local
# 3. インストール済みプラグイン本体を更新
claude plugin update crystal@yuki-local
# 4. 新しいセッションを開いて反映
```

## 構成

- `.claude-plugin/plugin.json` — plugin マニフェスト(`name: crystal`)
- `.claude-plugin/marketplace.json` — ローカルマーケットプレイス定義(`name: yuki-local`)
- `hooks/hooks.json` — hooks 登録。コマンドは `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` を参照する

## 前提

- hooks は `node` / `jq` が PATH にあることを前提とする。
- goal-gate と eval の rubric 判定は `claude` CLI が PATH にあり認証済みであることを
  前提とする。満たさない場合は判定をスキップする(fail-open)。
- `rules/` は SessionStart hook が注入するため、プラグインを有効化するだけで適用される。
  外部の CLAUDE.md からの参照は不要。
- 外側ループの周期実行(`/loop`・Routines)と worktree による並列隔離は Claude Code の
  組み込み機能に委譲している。プラグイン側にスケジューラや worktree 管理は持たない。
- `/crystal:loop refill` は GitHub MCP に依存する。接続が無いセッションでは、
  ラベルを尋ねる前にその旨を報告して終了する。
