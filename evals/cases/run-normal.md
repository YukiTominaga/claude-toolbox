---
id: run-normal
type: command
description: 無人実行が定数のターン上限で起動し、実費を記録し、start 行を 1 行だけ積む
run: evals/bin/loop-cases.sh run-normal
expect_exit: 0
expect_output: ^OK:
---
## メモ

`loop-run.sh` は `claude -p` を起動するので、そのままでは課金なしに検証できない。
`CRYSTAL_LOOP_CMD` で中身を差し替えられるようにして、スクリプト本体の
「実行ゲート → 実行 → 実費の記録 → 照合」の流れだけを決定的に検証する
(`CRYSTAL_JUDGE_CMD` と同じ手口)。

**ターン上限がスクリプト内の定数であることを見ている**。`LOOP.md` に別の値
(`max_turns_per_run: 123`)を書いた状態で起動し、渡る引数が定数側の値になること、
かつ宣言側の値が渡らないことを両方向で確認する。無人実行の歯止めを `LOOP.md` に置くと、
そのファイルはループ自身の編集対象なので**自分で緩められる上限**になってしまう。

**start 行を 1 行だけ積むことも明示的に見ている**。実測で、loop-run.sh がゲートを
記録付きで呼び、その後の `/crystal:loop next` の手順 1 が同じゲートをまた記録付きで
呼んでいた。1 イテレーションで start 行が 2 行積まれ、台帳の実行回数が倍になる。
