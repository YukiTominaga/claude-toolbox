---
id: run-normal
type: command
description: 無人実行が実費を記録し、予算を 1 回だけ消費する
run: evals/bin/loop-cases.sh run-normal
expect_exit: 0
expect_output: ^OK:
---
## メモ

`loop-run.sh` は `claude -p` を起動するので、そのままでは課金なしに検証できない。
`CRYSTAL_LOOP_CMD` で中身を差し替えられるようにして、スクリプト本体の
「予算ゲート → 実行 → 実費の記録 → 照合」の流れだけを決定的に検証する
(`CRYSTAL_JUDGE_CMD` と同じ手口)。

**予算を 1 回だけ消費することを明示的に見ている**。実測で、loop-run.sh がゲートを
記録付きで呼び、その後の `/crystal:loop next` の手順 1 が同じゲートをまた記録付きで
呼んでいた。1 イテレーションで start 行が 2 行積まれ、`max_runs_per_day` が黙って半分になる。
