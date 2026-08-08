# Decisions

<!-- 決定した瞬間に追記する生の記録。rules/decision-log.md を参照。
     追記のみ。ADR 化したエントリには末尾に `→ ADR-NNNN` を付ける。 -->

## 2026-08-08: crystal のハーネスを 5 つの目的に絞り、goal ループと eval を落とす

- 決めたこと: plugin が担う目的を「ADR / spec / 別文脈での検証 / テストの対 / 学びの記録」の
  5 つに固定し、そこに当たらない goal ループ一式(約 1,240 行)と eval 一式(約 305 行)、
  `log-bash.sh`、`audit-config.sh`、`pre-bash-guard.sh`、目的外の rules 3 本を削除した。
- 理由: 5 目標に当たらないコードが約 1,790 行あったのに対し、目的 2(spec)は 66 行・
  目的 3(別文脈での検証)は 38 行しか無く、投資配分が目的に対して逆転していた。
  さらに goal ループの存在が目的 3 を直接殺していた — `verifier` を日常フローで
  呼ばない理由が「stop-gate / goal-gate と合わせてテストが三重に走るから」であり、
  goal-gate を外すとこの制約が消える。
- 採らなかった案:
  - **goal ループを別 plugin に切り出す**: 履歴は残るが、`/adr` と `/learn` が
    `goal-gate.jsonl` を情報源として参照していたため、分離しても依存が残り続ける。
    参照を切るなら削除と同じ作業量になるので、git 履歴に残すことで足りると判断した。
  - **eval を残して目的 4 に流用する**: eval は「再発防止の資産」で、
    「実装と対になるテストが書かれる」とは別物。プロジェクトのテストスイートで
    やるべきことを二重化するだけだった。
  - **`pre-bash-guard.sh` を settings.json の permissions へ移す**: 破壊コマンドの
    抑止自体が 5 目的のどれでもない。移設先を用意すると「移した先の保守」が
    plugin の責務として残るため、plugin からは落としきる方を採った。
- 影響範囲: `hooks/`(6 本に縮小)、`commands/`(3 本に縮小)、`rules/`(3 本に縮小)、
  `scripts/`、`templates/`、`tests/`、README、`.claude-plugin/*.json`(v0.9.0)
  → ADR-0001

## 2026-08-08: 目的 3 は「verifier サブエージェントの呼び出しを強制する」形で実現する

- 決めたこと: `verify-gate.sh`(Stop hook)がメインセッションの transcript を読み、
  「最後のコード変更より後に `crystal:verifier` の呼び出しがあるか」を判定する。
  無ければ exit 2。判定は最後に現れた印(EDIT / VERIFY)を見るだけ。
- 理由: 目的 3 を掲げながら、verifier の description には「日常の完了報告の前には
  使わない」と書かれていて実質封印されていた。goal-gate を削除して三重実行の理由が
  消えたため、呼び出しの有無という機械判定できる事実を hook に移した。
- 採らなかった案:
  - **`claude -p` で本当に別セッションを起こす**: 目的 3 の文言(「別のセッション」)には
    最も忠実だが、削除したばかりの nested claude 構造が戻る。コスト・認証環境依存が
    大きく、判定結果を会話に戻す経路が stderr しか無い。サブエージェントでも
    「会話の経緯を引き継がない独立コンテキスト」という実質は得られるので見送った。
  - **worktree 隔離を必須にする**: 実装が汚したツリーではなくクリーンな状態で検証できるが、
    ビルドキャッシュが効かず検証が遅くなる。まずは文脈の隔離だけを取る。
  - **「一度でも verifier を呼んだか」で判定する**: 指摘を直した後の状態が検証されない
    まま完了できてしまう。最後の変更との前後関係を見る形にした。
  - **verifier の判定内容(満たす/満たさない)までゲートで見る**: verifier の出力形式に
    hook が依存し、書式を変えた瞬間に静かに壊れる。担保するのは「独立検証を経たこと」
    までに留めた。
- 影響範囲: `hooks/verify-gate.sh`(新規), `hooks/lib/classify.sh`(新規), `hooks/hooks.json`,
  `hooks/change-gate.sh`, `agents/verifier.md`, `tests/verify-gate.test.ts`
  → ADR-0002

## 2026-08-08: verifier の合否は「番兵 1 行」で読む

- 決めたこと: verifier に本文末尾で `CRYSTAL-VERDICT: PASS` / `CRYSTAL-VERDICT: FAIL <条件ID>`
  を 1 行返させ、`verify-gate.sh` は対応する `tool_result` からその 1 行だけを読む。
  FAIL なら差し戻す。判定行が読めないときだけ `stop_hook_active` を尊重して 1 度で諦める。
- 理由: 「検証を回したか」だけでは、verifier が「満たさない」と言っているのを無視して
  完了できてしまう。当初は「出力形式に依存すると書式変更で静かに壊れる」ことを理由に
  合否判定を見送っていたが、壊れ方を静かでなくすれば解決する問題だった。
  番兵の一致を `tests/verify-gate.test.ts` が hook と `agents/verifier.md` の両方を
  読んで検査するため、書式を変えるとテストが落ちる。
- 採らなかった案:
  - **判定サマリー(`満たさない: N件`)を正規表現で読む**: 自由記述の一部なので、
    verifier が言い回しを変えるたびに壊れる。本文に紛らわしい文字列があると誤判定もする
    (実際に「満たさない: 0件 と書いてあるが紛らわしい文章」で回帰テストを置いた)。
  - **verifier に判定 JSON をファイルへ書かせる**: 書き忘れると差し戻しが続き、
    書き忘れを直す手段が verifier 側にしかないため抜けられなくなる。
  - **受け入れ条件そのものを機械実行する**(AC に検証コマンドを併記して exit code で判定):
    削除した goal-gate の DC 検証と同じ機構が戻る。判定は verifier に委ね、
    ゲートはその結論だけを読む形に留めた。
  - **判定行が無い場合も詰まるまで差し戻す**: 古い crystal がインストールされていると
    判定行が返らず、`claude plugin update` を打つ前に応答を終えられなくなる。
- 影響範囲: `hooks/verify-gate.sh`, `agents/verifier.md`, `tests/verify-gate.test.ts`,
  `docs/spec/verify-gate.md`
  → ADR-0003

## 2026-08-08: 目的 2・4 のゲートは「1 度だけ差し戻す」形にする

- 決めたこと: `change-gate.sh` は `stop_hook_active` の再停止で素通しする。
  免除に当たる場合は理由を報告に書けば通る。
- 理由: 免除(既存テストで担保されるリファクタ / 仕様が変わらないバグ修正 /
  使い捨てスクリプト)は差分の形からは区別がつかない。免除まで機械判定しようとすると
  誤検知が出て、誤検知するゲートは最終的に丸ごと無視される。
  「黙って書き忘れる」は止め、「理由を述べて省く」は通す、という線引きにした。
- 採らなかった案:
  - **`stop_hook_active` を無視して毎ターン差し戻す**(旧 goal-gate と同じ設計):
    免除に当たる変更で永久に応答を終えられなくなる。ランタイム側のブロック上限
    (既定 8 回)に当たるまで無駄なターンを消費する。
  - **免除マーカーのファイルを置かせる**(`.claude/pairing-exempt` 等): 消し忘れが
    残ると以降ずっとゲートが無効になり、無効になったことに誰も気づけない。
- 影響範囲: `hooks/change-gate.sh`, `rules/testing.md`, `tests/change-gate.test.ts`
  → ADR-0004

## 2026-08-08: サブエージェントの編集は SubagentStop の記録で捕捉する

- 決めたこと: `record-subagent-edits.sh`(SubagentStop)が「コードを変更した
  サブエージェントがいた」事実だけを状態ファイル
  (`~/.claude/state/crystal/<session_id>.subagent-code-edits`)に残し、
  Stop 側のゲートがそれを読む。verify-gate が PASS を受理した時点で記録を消す。
- 理由: メイン transcript には Task の起動しか現れず、実装をサブエージェントに
  委譲するだけで verify-gate が丸ごと沈黙する(敵対的レビューで再現)。
  どの Task 起動が編集したかは tool_use id と agent_id の対応が取れないため、
  「いた/いなかった」の事実と印の順序だけで判定し、検証後の起動は
  1 度だけ差し戻して理由の明示で通す。
- 採らなかった案:
  - **transcript の timestamp と記録時刻の比較で順序を取る**: メイン transcript の
    timestamp 形式と `date` の出力形式の突き合わせが環境依存(BSD/GNU)になり、
    形式が変わった日に静かに壊れる。順序は印の並びだけから取る形にした。
  - **すべての Task 起動を無条件に変更痕跡とみなす**: 調査エージェントを
    走らせただけのターンが毎回差し戻される。verify-gate は stop_hook_active で
    折れない設計なので、抜けられないループになる。
  - **`claude -p` で検証を別プロセス化して委譲問題ごと消す**: 既存 ADR 相当の
    判断(コスト・認証環境依存・結果を会話へ戻す経路)で棄却済み。
- 影響範囲: `hooks/record-subagent-edits.sh`, `hooks/verify-gate.sh`,
  `hooks/change-gate.sh`, `hooks/stop-gate.sh`, `hooks/lib/classify.sh`, `hooks/hooks.json`
  → ADR-0005

## 2026-08-08: 差し戻しの自他は状態ファイルで区別する

- 決めたこと: change-gate / stop-gate は差し戻した事実を
  `~/.claude/state/crystal/<session_id>.<gate>.blocked` に記録し、
  `stop_hook_active` の再停止では「自分の記録があるときだけ」素通しする。
- 理由: `stop_hook_active` は「どれかの Stop hook が差し戻した」フラグで、
  自分が差し戻したかは分からない。フラグだけで折れると、change-gate の差し戻し後に
  追加された壊れたテストを stop-gate が一度も実行しないまま完了できる
  (ゲート間の相互干渉。敵対的レビューで指摘)。
- 採らなかった案:
  - **stop-gate も verify-gate と同様に stop_hook_active で折れない設計にする**:
    元から落ちているテストを直せないプロジェクトで、ランタイムのブロック上限まで
    詰まる。脱出口(自分の差し戻し後の再停止では素通し)は残す必要がある。
  - **フラグでの素通しを全廃する**: session_id が取れないビルドで無限ループになる。
    session_id 不明時は従来挙動(フラグで素通し)に落とす。
- 影響範囲: `hooks/change-gate.sh`, `hooks/stop-gate.sh`, `hooks/lib/classify.sh`
  → ADR-0006


## 2026-08-08: ゲートの比較基点を「セッション開始時点の HEAD」に固定する

- 決めたこと: `record-baseline.sh`(SessionStart)がセッション開始時点の HEAD を
  状態ファイル(`<session_id>.baseline`)に記録し、change-gate / verify-gate /
  stop-gate は `changed_files` の基点にこれを使う(commit 済みの変更も判定対象になる)。
  記録できない環境では従来どおり HEAD 比較にフォールバックする(fail-open)。
- 理由: 敵対的レビューで「応答を終える前に `git commit` するだけで 3 つの Stop ゲートが
  全て沈黙する」ことが実証された。commit はタスク完了と同義の通常運転(リモート
  セッションでは必須)で、「欺瞞は止めない」という保証範囲の外側 = 止めるべき側にある。
- 採らなかった案:
  - **transcript から `git commit` コマンドを検出して差分に足す**: commit の検出は
    できても「何が commit されたか」は transcript からは復元できず、結局 git に
    問い合わせる基点が要る。基点を 1 つ記録する方が単純で頑健。
  - **既定ブランチとの merge-base を基点にする**: 長生きブランチでは他人の変更まで
    差分に含まれ、セッションと無関係な指摘で毎ターン差し戻す誤検知になる。
  - **resume / compact の SessionStart で基点を進める**: そのセッションで commit 済みの
    変更が判定から漏れる。既存の記録があれば上書きしない形にした。
- 影響範囲: `hooks/record-baseline.sh`(新規), `hooks/lib/classify.sh`,
  `hooks/change-gate.sh`, `hooks/verify-gate.sh`, `hooks/stop-gate.sh`, `hooks/hooks.json`

## 2026-08-08: ベースライン方式の再差し戻しはダイジェスト記録で抑える

- 決めたこと: ベースライン方式では解消済み・免除済みの差分がセッション中ずっと残るため、
  (a) change-gate は免除で通した指摘のダイジェスト(対象実装ファイル + 欠けている対)を
  記録して同一の指摘では再差し戻ししない、(b) stop-gate は検査が通ったツリー状態の
  ダイジェスト(HEAD + 追跡差分 + 未追跡の中身)を記録して同一状態では再検査しない。
- 理由: 記録が無いと、免除後・検証後の会話だけのターンでも毎回差し戻し/フルテストが
  走り、「会話のたびに鳴る警報」になってゲートごと無視される(既存設計が最も
  避けてきた失敗モード)。
- 採らなかった案:
  - **ゲート通過時にベースラインを進める**: Stop hook は並列に走るため、片方のゲートが
    基点を進めると他方の未解決の指摘が消える競合が起きる。基点は不変にし、
    ゲートごとの記録で吸収した。
  - **時間ベースの抑制(N 分間は再検査しない)**: 状態が変わったのに検査しない
    見逃しと、変わっていないのに検査する無駄の両方を生む。状態のダイジェストなら
    どちらも起きない。
  - **cksum ではなく sha256 等**: 衝突耐性は不要(敵対的に衝突させる動機が無い)で、
    依存を増やさない方を優先した。
- 影響範囲: `hooks/lib/classify.sh`(`crystal_digest` / `tree_digest`),
  `hooks/change-gate.sh`, `hooks/stop-gate.sh`

## 2026-08-08: BASH_WRITE_RE の盲点拡張と verifier 判定の限定

- 決めたこと: (a) `BASH_WRITE_RE` に `cp` / `mv` / `rsync` / `truncate` / `ln` /
  `git merge|cherry-pick|pull|rebase` / `find・xargs 経由の sed/perl -i` を追加。
  (b) verify-gate の verifier 判定を部分一致(`verifier` を含む)から
  `(^|[:/])verifier$` に限定。(c) verify-gate の差し戻しメッセージから
  `CRYSTAL_VERIFY_GATE=off` の案内を除去(人間向けの README には残す)。
- 理由: (a) は敵対的レビューで素通りが実証された系統(「生成したファイルを cp で
  配置する」は欺瞞ですらない普通のワークフロー)。(b) は判定行の契約を持たない他所の
  「〜verifier〜」エージェントで VERIFY 印が立ち、「判定行が読めないときは 1 度で
  諦める」経路から抜けられるため。(c) は監督される側に監督の外し方を教える誘引で、
  除去しても人間の kill switch は失われない。
- 採らなかった案:
  - **すべての Bash 実行を書き換え候補とみなす**: change-gate のスコープが常にツリー
    全体に広がり、stop-gate が会話ターンでも走る誤検知の害が上回る。
  - **インタープリタ実行(`python gen.py` 等)も検出する**: コマンド文字列から
    書き込みの有無は判定できない。既知の残存経路として README に明記するに留めた。
- 影響範囲: `hooks/lib/classify.sh`, `hooks/verify-gate.sh`, README

## 2026-08-08: ハーネス自身の死活は doctor.sh(SessionStart)と CI で守る

- 決めたこと: (a) `doctor.sh` が SessionStart で `jq` / `git` / `node` の欠落を検出し、
  警告をコンテキストに注入する(jq 非依存で実装)。(b) GitHub Actions が push / PR ごとに
  `npm test` + hook の構文検査(`bash -n` / `node --check`)を実行する。
- 理由: 全ゲートが fail-open のため、依存欠落や構文エラーで「プラグイン全体が無症状で
  死ぬ」。README 自身が「壊れても手動 E2E では気づけない」と認めながら、それを検出する
  仕組みが無かった。
- 採らなかった案:
  - **ゲート側で依存欠落時に exit 2**: fail-open をやめると、依存の無い環境で
    全ターン差し戻しになり plugin ごと外される。検査は素通しのまま、警告だけを出す。
  - **CI に shellcheck を追加**: 実行環境で事前検証できず(バイナリ取得がプロキシで
    拒否される)、未検証の lint を CI に入れると初回から赤になるリスクがある。
    構文検査(`bash -n`)のみ入れ、shellcheck は将来の改善とした。
- 影響範囲: `hooks/doctor.sh`(新規), `hooks/hooks.json`, `.github/workflows/test.yml`
