---
id: goal-gate-migrate
type: command
description: 旧形式の goal.md にも停止条件のフィールドを補える
run: evals/bin/loop-cases.sh goal-migrate
expect_exit: 0
expect_output: ^OK:
---
## メモ

停止条件の追加で既存のゴールファイルが壊れないこと(後方互換)。
