# 仕様: 予算 3 項目を撤廃し、対話セッションを無制限にする

- 日付: 2026-07-25
- 関連 Issue / チケット: `docs/backlog.md` の 2 項目(第 1 便 = 時間、第 2 便 = 回数とターン数)がこの仕様を参照する
- ステータス: approved

用語: **予算** = `LOOP.md` frontmatter の `max_runs_per_day` / `max_minutes_per_run` /
`max_turns_per_run` の 3 項目と、それを強制する機構。
**導線** = モデルに指示を与える側のファイル(`commands/` `templates/` `README.md` `LOOP.md`)。
**反転** = eval ケースを削除せず、「止めないこと」を固定する側に書き換えること。

## 承認

この変更は `LOOP.md:37`(frontmatter は触れてはいけない範囲)と `LOOP.md:92`
(予算 3 項目の変更は人間承認ゲート)に正面から該当する。
2026-07-25 に人間が撤廃を指示しており、**その指示が承認そのものである**。
実装者および無人ループは、ゲートに該当することを理由に `blocked` で終了しないこと。

## 目的(なぜやるか)

予算はループの暴走を止めるために置かれたが、実運用では対話セッションの邪魔にしかなっていない
(2026-07-25 のセッションで「本日 4/8 回」が可視化され、人間が撤廃を決定した)。
対話セッションでは回数・時間・ターン数のいずれによってもループが止まらないようにする。

3 項目はそれぞれ別の場所で効いている:

| 項目 | 強制する場所 | 効き方 |
|---|---|---|
| `max_runs_per_day` | `scripts/loop-guard.sh:69` | 台帳の当日の `{"event":"start"}` 行を数え、上限以上なら exit 1 |
| `max_minutes_per_run` | `hooks/goal-gate.sh:76-128` | `.claude/goal.md` の `max_minutes` に転記し、経過時間が超えたら `status: stalled` |
| `max_turns_per_run` | `scripts/loop-run.sh:42-46` | 無人実行に `--max-turns` として渡す |

**frontmatter から 3 行を消しても撤廃にならない**。`loop-guard.sh:53-55` は欠落・非数値のとき
8 / 30 / 300 をハードコードで補い、`goal-gate.sh:80` は `LOOP.md` が無ければ 60 分を使う。
宣言を消すと「緩むが残る」状態になり、なぜ止まったかが読み取れない分むしろ悪化する。
機構そのものを外す必要がある。

`started_epoch`(`.claude/goal.md`)は経過時間の判定にしか使われておらず、
時間判定を外すと読み手が 1 つも無くなる。

### 無人実行の歯止めは残す(人間の決定)

`max_turns_per_run` は `loop-run.sh` 専用で、対話セッションには一切効かない。
つまり撤廃の動機(対話の不便)とは無関係である。一方で、これを外すと無人実行の歯止めが
実質ゼロになる:

- `max_rounds` が数えるのは Stop hook の発火回数であり、1 ラウンド内のツール呼び出し数・
  壁時計時間には上限がない。`--max-turns` を外すと 1 ラウンドの長さに機械的上限がなくなる
- `hooks/goal-gate.sh:28`(goal.md 不在)と `:74`(`status != active`)は即 `exit 0` するため、
  その間は `max_rounds` も `max_no_progress` も効かない。これは文書化済みの実障害である
  (Q-8、`commands/loop.md:110-129`)

よって **`--max-turns` は `loop-run.sh` 内の定数として残す**。`LOOP.md` からは宣言を消し、
ループが自分で緩められない形にする。

## スコープ

### 含む

- `scripts/loop-guard.sh` の回数判定の削除(ハードコード既定値ごと)
- `hooks/goal-gate.sh` の時間判定の削除(ハードコード既定値ごと)、`max_minutes` と
  `started_epoch` の書き込みの停止
- `scripts/loop-run.sh` が `LOOP.md` の `max_turns_per_run` を読むのをやめ、定数に置き換える
- `LOOP.md` frontmatter の 3 行と、本文の予算に関する記述
- 導線の追従: `templates/loop.md` `templates/goal.md` `commands/loop.md` `commands/goal.md`
  `README.md`
- 影響する eval ケースの反転・更新

### 含まない

- `status: paused` による停止(手動の停止スイッチであり予算ではない。従来どおり exit 1 する)
- **`LOOP.md` ゲート節の `status` に関する記述と理由づけ**。3 項目と `status` は同じ箇条書きに
  同居している。3 項目を消すついでに箇条ごと落とすと、残った最後の歯止めの
  自己書き換え禁止が消える
- 台帳への `{"event":"start"}` の記録と、`loop-guard.sh` 出力の `runs_today` キー。
  回数は**測り続ける**(止めないだけ)。`commands/loop.md` の報告がこれを読む
- `.claude/goal.md` の `max_rounds`(既定 5)と `max_no_progress`(既定 2)
- **`scripts/loop-smoke.sh`**。`:82` の `--max-turns 12` は L3 スモーク自身の歯止めであり、
  実 Claude 実行を無制限にしてはならない。`:62-63` の `started_epoch` / `max_minutes: 10` は
  死んだフィールドになるが触らない(実 Claude Code を回すので変更の副作用が読めない)
- `scripts/loop-run.sh` の多重起動防止(flock / PID ファイル)。`max_runs_per_day` は事実上
  多重起動も抑えていたため撤廃で穴が開くが、この仕様では扱わない。signal に残して別項目にする
- 無人実行が異常終了を台帳に記録する機能
- 実費 (`total_cost_usd`) の記録(従来どおり記録のみ。判定には使わない)
- 新しい歯止めの追加(コスト上限などを代わりに設けない)
- `docs/backlog.md` の Q-12(予算ゲートの迂回経路を塞ぐ項目)と Q-9 の見送り理由
  (`max_minutes_per_run: 30` を根拠にしている)の扱い。前提が消えるが、再定義するか
  見送るかは人間が決める
- `docs/spec/Q-7.md` など過去の仕様に残る「停止条件 4 層」への言及(履歴なので書き換えない)

## 設計上の決定(実装が従うこと)

- **走行中のセッションでは自分の変更が効かない**。`scripts/loop-run.sh:6-8` が明記するとおり、
  プラグインはキャッシュへの実コピーで hooks はセッション開始時に固定される。したがって
  「時間判定を先に外せば作業中に stalled にならない」は成立しない。第 1 便を実行する
  イテレーションでは `.claude/goal.md` に `max_minutes: 999` を明示して作る
  (`commands/goal.md:52-54` が許している経路)。リポジトリ側の修正が実際に効くのは
  version バンプ + `claude plugin update` 後の新セッションである
- 欠落時のハードコード既定値は**値を大きくするのではなく判定ごと削除する**。値が残っていると
  「宣言していないのに止まる」という現状の欠陥がそのまま残る
- `loop-guard.sh` は判定を失っても**出力の JSON 形状を保つ**(`ok` を持つ 1 行、`runs_today` を
  含む)。`loop-run.sh` が `jq -r` で読むため、形が変わると無人実行が壊れる
- 停止条件は **4 層 → 3 層に詰め、無進捗を「停止条件 3」に繰り上げる**。番号は
  `hooks/goal-gate.sh:8-12` `README.md:184-191` `commands/goal.md:15-16,62-65`
  `templates/goal.md:23-32` `LOOP.md:69` `templates/loop.md:60`
  `evals/cases/goal-l1-after-stop-rules.md:15` に散っており、同じ変更に含める
- **実装・導線・eval を同一イテレーションに置く**。実装だけ直して導線が古い指示を残すと、
  モデルが `max_minutes` を手で書き戻して復活する(`evals/cases/goal-minutes-from-loop.md`
  が記録している失敗の型)
- 2 便に割る境界は**強制する場所**で引く。第 1 便 = 時間(`goal-gate.sh` 側)、
  第 2 便 = 回数とターン数(`loop-guard.sh` / `loop-run.sh` 側)。
  各便の末尾で eval スイートが exit 0 になること

## 受け入れ条件

### 第 1 便: 時間 (`max_minutes_per_run`) の撤廃

- AC-A1: `started_epoch` を 10 年前にした goal.md で goal-gate を 1 回起動すると、
  `status` が `active` のまま、`round` が 1、かつ L1 スタブの呼び出し回数が 1 になる
  (停止条件で抜けていない)。(`goal-gate-budget` を反転)
- AC-A2: goal-gate は `.claude/goal.md` に `max_minutes` と `started_epoch` を書き込まない。
  両フィールドを持たない goal.md を与えて 1 回起動したあと
  `! grep -qE '^(max_minutes|started_epoch):' .claude/goal.md`。
  (`goal-minutes-from-loop` を「LOOP.md の値を引き継ぐ」から「どちらも作らない」に反転)
- AC-A3: `! grep -q 'max_minutes' templates/goal.md` かつ
  `! grep -q 'started_epoch' templates/goal.md`。**解説コメントからも消す**
  (行だけ消してコメントを残すとモデルが書き戻して復活する)
- AC-A4: `! grep -q 'max_minutes\|started_epoch' commands/goal.md commands/loop.md`。
  この grep は `max_minutes_per_run` にも当たるため、`commands/loop.md:43` の粒度基準
  「1 項目が `LOOP.md` の `max_minutes_per_run` に収まること」の差し替え
  (→「1 項目 = AC-* を満たせる最小単位」)は**第 1 便に含まれる**(第 2 便ではない)
- AC-A5: 停止条件が 3 層に詰められ、無進捗が「停止条件 3」になっている。設計上の決定で
  挙げた 7 ファイルに「停止条件 4」への参照が 0 件(`docs/spec/` は対象外)
- AC-A6: `LOOP.md` frontmatter から `max_minutes_per_run` の 1 行が消え、「5. 停止条件」の
  記述から時間が消えている。回数とターン数の 2 行はこの便では残す
- AC-A7: eval が更新されている。`goal-gate-budget` と `goal-minutes-from-loop` は反転。
  `goal-gate-migrate`(`evals/bin/hook-cases.sh:745` の `for k in ... started_epoch max_minutes`)
  と `goal-l1-after-stop-rules`(`hook-cases.sh:414-419` の (b) 壁時計予算)は該当
  sub-assertion のみ削除。共有ヘルパ `write_goal`(`hook-cases.sh:115-137`、14 箇所から呼ばれる)
  は 2 フィールドを出力しない形にし、呼び出し側 14 箇所すべてが PASS すること
- AC-A8: `CLAUDE_PROJECT_DIR=$(pwd) ./scripts/eval-run.sh` が exit 0(不合格 0 件)
- AC-A9: ミューテーション確認 — 時間判定を戻すと AC-A1 / AC-A2 のケースが落ちること
  (`LOOP.md:73-75` の要求)

### 第 2 便: 回数 (`max_runs_per_day`) とターン数 (`max_turns_per_run`) の撤廃

- AC-B1: `LOOP.md` に `max_runs_per_day: 2` を書き、台帳に当日日付の `{"event":"start"}` 行を
  100 件置いた状態で、`loop-guard.sh` が `ok:true` / exit 0 を返し、出力に
  `max_runs_per_day` キーが現れない。台帳の行は `"ts":"<今日>"` と `"event":"start"` が
  同一行にある形で書く(`loop-guard.sh:65` の grep がそう数えるため)。
  (`loop-guard-budget` を反転。**宣言が残っていても効かない**ことを固定する)
- AC-B2: `loop-guard.sh` を N 回呼ぶと台帳の `grep -c '"event":"start"'` が N になり、
  `--check` では増えない。出力は `runs_today` キーを持つ
  (反転後の `loop-guard-budget` と `loop-guard-check` の両方で固定する。
  現在この追記を検証している唯一の assertion は反転対象の中にあるため、消さないこと)
- AC-B3: `status: paused` のとき従来どおり `ok:false` / exit 1(`loop-guard-paused` が
  現状のまま PASS すること)
- AC-B4: `LOOP.md` に `max_turns_per_run: 123` を書いても、`loop-run.sh` が渡す引数は
  `--max-turns 300`(スクリプト内の定数)になる。(`run-normal` を更新)
- AC-B5: `run-records-abort` のスタブ(`evals/bin/loop-cases.sh:37-56`)と assertion を
  **変更しない**。打ち切りは `subtype: error_max_turns` で再現されており `--max-turns` に
  依存しない。変更してよいのは `evals/cases/run-records-abort.md:19-21` の説明文だけ
- AC-B6: `LOOP.md` frontmatter に予算 3 項目が無い。かつ `templates/loop.md` の
  frontmatter 3 行・行末コメント・「5. 停止条件」の予算行が消えている
  (`/crystal:loop init` で復活しないこと)
- AC-B7: `grep -rl 'max_runs_per_day\|max_minutes_per_run\|max_turns_per_run\|--max-turns' .`
  の結果に `hooks/` `commands/` `templates/` `README.md` `LOOP.md` のファイルが 1 件も無く、
  `scripts/` は `loop-smoke.sh` と `loop-run.sh`(定数)のみ。残ってよいのは `docs/` `evals/`
  `.claude/learnings.md`(履歴・撤廃を固定する eval・仕様)
- AC-B8: `commands/loop.md` の**回数**に依存する記述が更新されている。手順 1 の
  「予算超過」(`:79`)、報告書式「本日 `<n>/<max>` 回」(`:145`)、`status` 報告(`:170-173`)。
  粒度基準は第 1 便の AC-A4 で処理済み
- AC-B9: `README.md`(`:86-99` と `:190`)と `LOOP.md`「5. 停止条件」が撤廃後の実装と一致し、
  残る歯止めとして `max_rounds` / `max_no_progress` / `status: paused` / 無人実行の
  `--max-turns` 定数 を挙げている。`LOOP.md:19-20` の昇格表の `/loop 30m` は 30 分予算
  由来なので表記を見直す
- AC-B10: `LOOP.md` ゲート節に `status` の自己書き換え禁止とその理由が残っている
- AC-B11: `CLAUDE_PROJECT_DIR=$(pwd) ./scripts/eval-run.sh` が exit 0(不合格 0 件)
- AC-B12: ミューテーション確認 — 回数判定を戻すと AC-B1 のケースが、`LOOP.md` から
  ターン数を読む形に戻すと AC-B4 のケースが落ちること
