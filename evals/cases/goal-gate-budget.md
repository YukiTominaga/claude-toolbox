---
id: goal-gate-budget
type: command
description: 経過時間が max_minutes を超えたら stalled で止まる
run: evals/bin/loop-cases.sh goal-budget
expect_exit: 0
expect_output: ^OK:
---
## メモ

停止条件 3 (予算)。判定器を呼ばずに止まることも同時に確認している。
