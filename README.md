# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## この plugin が担う 5 つのこと

crystal のハーネス部分は、次の 5 つだけを目的にしている。ここに当たらない仕組みは置かない。

| 目的 | 担うもの | 強制 |
|---|---|---|
| 1. 決定の理由を ADR に残す | `rules/decision-log.md` → `.claude/decisions.md` → `/crystal:adr` → `docs/adr/` + `adr-lint.sh` | 構造は機械検証 |
| 2. 実装と対になる spec が作られる | `/crystal:spec` → `docs/spec/` + `crystal:spec-critic` | `change-gate.sh` |
| 3. 実装とは別の文脈で検証する | `crystal:verifier` + `subagent-gate.sh` | `verify-gate.sh` |
| 4. 実装と対になるテストが必ず書かれる | `rules/testing.md` + `stop-gate.sh` | `change-gate.sh` |
| 5. 学びが次のセッションに残る | `rules/learning.md` + `/crystal:learn` → `.claude/learnings.md` → `session-learnings.sh` | — |

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個(ドメイン知識。ハーネスとは独立) |
| `agents/` | `spec-critic`(目的 2), `verifier`(目的 3) |
| `commands/` | `/spec`(2), `/learn`(5), `/adr`(1) |
| `hooks/` | `hooks.json` + スクリプト 8 本 + 共有ライブラリ `lib/classify.sh` |
| `scripts/` | `adr-lint.sh`(目的 1 の構造検証) |
| `rules/` | `testing.md`(4) / `learning.md`(5) / `decision-log.md`(1)。SessionStart hook が全セッションに注入 |
| `templates/` | `spec.md`(2), `adr.md`(1) |

hook の内訳:

| hook | イベント | 目的 |
|---|---|---|
| `session-rules.sh` | SessionStart | `rules/*.md` を注入 |
| `session-learnings.sh` | SessionStart | `.claude/learnings.md` を注入(目的 5 の回収) |
| `change-gate.sh` | Stop | 実装に対するテスト / spec の欠落を差し戻す(目的 2・4) |
| `verify-gate.sh` | Stop | 独立検証を通していない実装を差し戻す(目的 3) |
| `stop-gate.sh` | Stop | 変更があればテスト・型チェック・lint を実行して差し戻す |
| `subagent-gate.sh` | SubagentStop | 検証済みという完了報告の裏取り(目的 3 の補助) |
| `format-on-save.sh` / `lint-changed.sh` | PostToolUse | 編集したファイルの整形と lint |

分類の正規表現(何が実装で何がテストか)は `hooks/lib/classify.sh` に 1 つだけ置き、
`change-gate.sh` と `verify-gate.sh` が source する。2 つに書き写すと必ず片方だけ
直された状態が生まれる。

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、
> `~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール

```bash
claude plugin marketplace add YukiTominaga/claude-toolbox
claude plugin install crystal@yuki --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn` / `crystal:adr`
- サブエージェント: `crystal:spec-critic` / `crystal:verifier`
- スキル 11 個は `crystal` 由来でロード
- hooks(SessionStart/PostToolUse/SubagentStop/Stop)が自動登録され、
  `rules/*.md` はセッション開始時に自動でコンテキストへ注入される

## 標準の開発フロー

```
/crystal:spec <機能>   要件を詰める → 承認したら ステータス: approved に昇格
  ↓ 実装 (実装 + テスト + spec の 3 点が揃うまで change-gate が差し戻す)
  ↓ stop-gate が毎ターン テスト / 型チェック / lint を実行
crystal:verifier       別文脈での独立検証 (verify-gate が呼ぶまで応答を終えさせない)
/crystal:learn         知見を .claude/learnings.md に落とす
/crystal:adr <テーマ>  「なぜこの構成にしたか」を docs/adr/ に残す (決定をした回だけ)
```

作業中に決定をしたら、その場で `.claude/decisions.md` に書き残す(`rules/decision-log.md`)。
`/crystal:adr` はそれを一次情報として読む。

## 変更の対を機械検証する (`change-gate.sh`)

目的 2 と目的 4 は、どちらも「差分の形」で機械判定できる。散文で頼まずここに置いてある。

Stop のたびに変更ファイル(作業ツリー + index + 未追跡)を分類し、次のどちらかに当たれば
exit 2 で差し戻す:

- 実装ファイルが変わったのに、**テストファイルが 1 つも変わっていない**
- 実装ファイルが変わったのに、**`docs/spec/` が 1 つも変わっていない**

分類の規則:

| 種別 | 判定 |
|---|---|
| 実装 | `.ts .tsx .js .jsx .mjs .cjs .py .go .rs .rb .java .kt .swift .c .cpp .h .cs .scala .php .ex .dart .vue .svelte .sh` など。ただしテスト・設定を除く |
| テスト | `tests?/` `__tests__/` `specs?/` `e2e/` 配下、`*.test.*` `*.spec.*` `test_*.*` `*_test.*` `*Test.java` `conftest.py` |
| 設定(対象外) | `*.config.*`、`.*rc` / `.*rc.*` |
| spec | `docs/spec/` `docs/specs/` 配下の `.md` |

判定できないこと、および設計上の割り切り:

- **テストの中身が妥当かは見ない。** 空のテストを 1 つ置けば通る。中身は
  `stop-gate.sh`(実行して落ちるか)と `rules/testing.md`(何をテストするか)が担う
- **仕様と実装が一致しているかは見ない。** ファイルが変わったかだけを見る
- **免除は機械判定できない。** 既存テストで担保されるリファクタ、仕様が変わらない
  バグ修正、使い捨てスクリプト — どれも差分の形からは区別がつかない。そのため
  **1 度だけ差し戻し、`stop_hook_active` の再停止では素通しする**。免除に当たるなら
  その旨を報告に書いてから応答を終えれば通る。「黙って書き忘れる」は止まり、
  「理由を述べて省く」は通る、という線引き
- **プロジェクト単位で切れる。** `CRYSTAL_TEST_GATE=off` / `CRYSTAL_SPEC_GATE=off`。
  切れないゲートは、合わない現場では plugin ごと外されて全部が失われる

`docs/spec/` は `TEST_RE` の `specs?/` にも一致するため、テスト判定の前に spec を除いている。
除かないと「仕様を書いた = テストも書いた」ことになり、目的 4 のゲートが黙って死ぬ
(回帰テストあり)。

## 独立検証を強制する (`verify-gate.sh`)

目的 3 は「実装した文脈のまま自己申告で終える」ことを止めるためにある。
呼び出しの有無は機械判定できるので、散文ではなくここに置いてある。

Stop のたびにメインセッションの transcript を読み、時系列に並ぶ 2 種類の印だけを取る:

| 印 | 何から取るか |
|---|---|
| `EDIT` | `Write` / `Edit` / `MultiEdit` / `NotebookEdit` の `tool_use`(コードファイルのみ) |
| `VERIFY` | `Agent`(ビルドにより `Task`)の `tool_use` で `subagent_type` が `verifier` を含むもの |

**最後に現れた印が `VERIFY` でなければ差し戻す。** 「最後の変更より後に検証したか」を
これだけで判定できる。

- **`stop_hook_active` では素通ししない**(change-gate との意図的な設計差)。
  免除の余地がほとんど無く、verifier を呼べばその時点で印が `VERIFY` になって
  自然に通るため、ループにはならない
- **`Agent` と `Task` の両方を受ける。** サブエージェント起動ツールの名前は
  Claude Code のビルドによって変わる。片方だけを見ているとある日静かに無効化される
- **`docs/spec/` に仕様が 1 つも無ければ発火しない。** verifier は仕様の受け入れ条件を
  根拠に判定するため、仕様が無い状態で呼んでも「検証不能」しか返らず、
  差し戻しても状況が変わらない = 抜けられないループになる
- **検証後の `docs/spec/` 更新・設定ファイル更新は再検証を要求しない。**
  仕様のステータスを `approved` → `done` に変えただけで差し戻されると、
  「検証 → 仕様更新 → 差し戻し」で抜けられなくなる
- **`file_path` はプロジェクトルートを剥がしてから分類する。** 剥がさないと
  `/home/me/specs/proj/src/a.ts` のような親ディレクトリ名に引きずられる
- **Bash 経由の書き換え(`sed -i` 等)は取りこぼす。** リダイレクトを変更とみなすと
  ログ出力のたびに再検証を要求することになり、誤検出の害の方が大きい
- `CRYSTAL_VERIFY_GATE=off` で無効化できる

### 合格したかまで見る

「検証を回したか」だけでは、verifier が「満たさない」と言っているのを無視して
完了できてしまう。そこで verifier は本文の末尾に**判定行を 1 行**返す契約になっている:

```
CRYSTAL-VERDICT: PASS
CRYSTAL-VERDICT: FAIL AC-2, AC-5
```

ゲートは対応する `tool_result`(= verifier の戻り値)からこの 1 行だけを読む。
散文の要約は読解しない。`満たさない: 0件` のような紛らわしい文が本文にあっても、
判定行が `PASS` なら通す(判定基準を曖昧にしないため)。

- **「未検証」は PASS に含めない。** 実行結果で裏が取れていない条件は、
  満たしているかが分かっていないという意味であって合格ではない
- **`FAIL` は `stop_hook_active` でも折れない。** 直せば `PASS` になるので抜けられる。
  仕様の側が実態と合っていないなら `docs/spec/` を直すのが正しい解決になることもある
- **判定行が読み取れないときだけは 1 度で諦める。** 古い crystal がインストールされて
  いると判定行が返らない。ここで詰まらせると `plugin update` すら打てなくなるので、
  再停止では素通しする(「最後の変更より後に検証を回した」担保は既に取れている)

出力形式に依存する以上、契約が片側だけ書き換えられると判定が黙って無力化される。
これを防ぐため、`tests/verify-gate.test.ts` が `hooks/verify-gate.sh` と
`agents/verifier.md` の両方を読み、番兵の文字列と正規表現が一致していることを検査する。
書式を変えるなら、テストが落ちる。

サブエージェントは**別セッションではない**。同一セッション・同一ワークツリーで動く。
得られるのは「会話の経緯を引き継がない独立コンテキストが、仕様と実行結果だけで判定する」
という性質までで、実装が汚したツリーを見る点は残る。`claude -p` で本当に別プロセスを
起こす案は、コストと認証環境依存、判定結果を会話へ戻す経路が stderr しか無いことから
採らなかった。

`stop-gate.sh` と verifier でテストが二重に走る。verifier が動くのは「実装を変更した
まとまりごとに 1 回」なので許容している。

## 並行エージェント実行時の検証

サブエージェントを並列で走らせるとき、検証をどの層で走らせるかを分けている。

| 検証の粒度 | 走らせる場所 | 理由 |
|---|---|---|
| ファイル単位の lint / 整形 | `PostToolUse`(`lint-changed.sh` / `format-on-save.sh`) | サブエージェント内でも発火するため、変更した本人がその場で直せる |
| 完了報告の裏取り | `SubagentStop`(`subagent-gate.sh`) | 変更したうえで「テストが通った」と主張しているのに実行痕跡が無いものだけを止める。安く済む |
| プロジェクト全体の typecheck / test | 親の `Stop`(`stop-gate.sh`) | 並列エージェントは既定で worktree 隔離されず同一チェックアウトを共有する。同時にフルテストを走らせるとキャッシュ破壊と CPU 飽和を招く |
| 仕様(AC)単位の独立判定 | `crystal:verifier`(`verify-gate.sh` が強制) | 会話の文脈を持たない第三者判定。実装を変更したまとまりごとに 1 回だけ走る |

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

## ADR (意思決定の記録)

出典: [ADR 作成を Claude の Agent Skills で自動化する](https://blog.cybozu.io/entry/2026/07/28/090000)

「なぜこの構成にしたのか」「他にどんな選択肢があって、なぜ採らなかったのか」を
`docs/adr/NNNN-<slug>.md` に 1 決定 1 ファイルで残す。形式は `templates/adr.md`。

記事が挙げる課題と、このリポジトリでの対応:

| 記事の課題 | crystal での対応 |
|---|---|
| ADR 作成が後回しになり、書く頃には記憶が薄れている | `rules/decision-log.md` が**決定した瞬間に** `.claude/decisions.md` へ書かせる。ADR はそれを読んで後から起こす |
| 材料が作業ログ・仕様書・実装コードに散らばっている | `/crystal:adr` の「1. 情報収集」が `decisions.md` / `docs/spec/` / `learnings.md` / `git log` / 実装を横断して集める |
| いきなり全文を書くと方向がずれて手戻りが大きい | 「3. 内容確認」を**必須の合意チェックポイント**にし、項目ごとの骨子で合意してから清書する |
| 過去 ADR と文体が揃わない | 「4. 清書」で既存 `docs/adr/*.md` を読み、文体・粒度を合わせる |

記事が「鍵になる」としているのは skill ではなく**一次情報(作業ログ)が残っている文化**の方。
`.claude/learnings.md`(ハマりポイント)と `docs/spec/`(これから作るものの要件)はあっても、
**採らなかった案とその理由**を残す場所が無ければ、決定の「なぜ」は毎回セッションと
一緒に消える。`.claude/decisions.md` はその穴を埋める層で、散文で構わない代わりに
**却下案と却下理由を必ず含める**ことだけを要求する。

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
  無い決定ログはチームの ADR を支えられない。untracked のまま放置するのだけが誤りで、
  stop-gate の「変更なし判定」を汚す
- **`decisions.md` は追記のみ・全文ロードしない**。読み手が `/crystal:adr` だけなので
  注入側ではなく**読む側**で絞る。テーマで見出しを絞り込み、ADR 化済み
  (`→ ADR-NNNN` マーカー付き)は飛ばし、32KB を超えたら
  `.claude/decisions/YYYY.md` へ年分割する
- **裏が取れない項目は空けて出す**。記事も「記憶が薄れる問題は完全には解消されない」と
  している。特に却下理由は記録に残りにくく最も捏造しやすいため、
  `/crystal:adr` には材料が無い項目を「材料なし」と明示させ、
  もっともらしい理由で埋めることを禁じてある。誤った ADR は無い ADR より害が大きい

### 構造の機械検証 (`scripts/adr-lint.sh`)

ADR の品質のうち機械判定できる部分は散文に委ねず、`adr-lint.sh` に移してある
(`docs/adr` を検査。指摘があれば exit 1)。`/crystal:adr` は `list` / 清書後 /
`supersede` 後にこれを実行する。

| 検出するもの | なぜ散文では防げないか |
|---|---|
| 番号の重複 | 採番は「既存の最大 + 1」で、別ブランチ・worktree の ADR は手元から見えない |
| `superseded` の参照先不在・逆リンク欠落 | 2 ファイルにまたがる編集で、片方だけ済んだ状態を作りやすい |
| 必須セクションの欠落 | — |
| 却下案ゼロ | 却下案の無い ADR は「なぜ他を採らなかったか」を残せておらず、主価値を欠く |
| プレースホルダ(`NNNN` / `YYYY-MM-DD`)の残留 | テンプレートをコピーしただけの ADR を弾く |
| ステータス値・日付形式・見出し番号の不一致 | — |

**判定できないのは「却下理由が事実か」だけ**で、そこ以外は構造として締められる。
「ADR は本質的に機械検証できない」は正しくない。

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
# 3. マーケットプレイスのメタデータを更新
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

vitest で `change-gate.sh` / `verify-gate.sh` / `stop-gate.sh` / `subagent-gate.sh` / `session-learnings.sh` /
`adr-lint.sh` の振る舞いをテストしている。ゲートは fail-open 設計(異常時は黙って exit 0)なので、
壊れても手動 E2E では気づけない。`change-gate.sh` と `adr-lint.sh` は逆に**誤検出しないこと**が
要件で、ドキュメント修正のたびにテストを要求するようになるとゲートごと無視されるため、
正常系も明示的に押さえている。`tests/helpers/sandbox.ts` が使い捨ての git リポジトリを作る。

## 構成

- `.claude-plugin/plugin.json` — plugin マニフェスト(`name: crystal`)
- `.claude-plugin/marketplace.json` — マーケットプレイス定義(`name: yuki`)
- `hooks/hooks.json` — hooks 登録。コマンドは `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` を参照する

## 前提

- hooks は `node` / `jq` / `git` が PATH にあることを前提とする。
- `rules/` は SessionStart hook(`session-rules.sh`)が注入するため、プラグインを
  有効化するだけで適用される。外部の CLAUDE.md からの参照は不要。
- プロジェクトの `.claude/learnings.md` も SessionStart hook(`session-learnings.sh`)が
  注入する。`/crystal:learn` と `rules/learning.md` は知見をこのファイルに書き溜めるが、
  読み込む導線が無いと次のセッションで参照されない(書くだけで回収されない)ため。
  際限なく増えるので末尾 8000 バイトまでを載せ、エントリの途中で切らないよう
  見出し行から始める。切り詰めた場合はその旨を明記する。
- `.claude/decisions.md` は SessionStart で注入しない(読み手が `/crystal:adr` に限られるため)。

## rules/ の方針

プラグインには native な `rules/` コンポーネントが無い(公式のコンポーネントは
skills / agents / hooks / MCP / LSP / monitors)。そのため `session-rules.sh` で
`SessionStart` の `additionalContext` として注入しているが、この経路には
`.claude/rules/` のような `paths:` フロントマターによるスコープ限定が無く、
**全ファイルが毎セッション無条件で入る**。CLAUDE.md 以上に選別が要る。

採用基準は 2 つ:

1. **hook で強制できることは rules に書かない。** `stop-gate.sh` がテスト・型チェック・
   lint を実行し、`change-gate.sh` が差分の形を検査して exit 2 で差し戻す以上、
   同じことを散文で書いても遵守率は上がらず、コンテキストを消費するだけ。
   [Opus 5 のプロンプティングガイド](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5)
   も、旧世代向けの検証指示("include a final verification step" 等)は
   過剰検証を招くレガシー足場として削除を推奨している。
   残すのは**機械が判定できない部分**だけ(何をテストするか、何が免除に当たるか)。
2. **既定の挙動と一致することは書かない。** 「シンプルに書く」「secret を
   ハードコードしない」といった一般論は、書いても振る舞いが変わらない。

判定は「この行を消したら Claude が間違えるか?」で行い、答えが No なら消す。
