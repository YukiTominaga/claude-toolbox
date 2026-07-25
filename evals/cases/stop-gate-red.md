---
id: stop-gate-red
type: command
description: 変更があって赤なら差し戻す
run: evals/bin/hook-cases.sh stop-gate-red
expect_exit: 0
expect_output: ^OK:
---
## メモ

project-checks.sh への切り出し後も挙動が変わっていないことの固定。
