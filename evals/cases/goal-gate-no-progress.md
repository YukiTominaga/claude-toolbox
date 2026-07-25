---
id: goal-gate-no-progress
type: command
description: 差分が変わらないラウンドが続いたら stalled で止まる
run: evals/bin/hook-cases.sh goal-no-progress
expect_exit: 0
expect_output: ^OK:
---
## メモ

停止条件 3 (無進捗)。ラウンド上限だけに頼ると、進まないまま上限まで課金される。
