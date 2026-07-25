---
id: goal-l1-green-passes
type: command
description: 緑なら判定器の層まで到達する
run: evals/bin/hook-cases.sh goal-l1-green-passes
expect_exit: 0
expect_output: ^OK:
---
## メモ

L1 ゲートが常に差し戻すようになっていないこと (fail-open が壊れていないこと)。
