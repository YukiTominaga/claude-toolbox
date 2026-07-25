---
id: stop-gate-green
type: command
description: 変更があって緑なら通す
run: evals/bin/hook-cases.sh stop-gate-green
expect_exit: 0
expect_output: ^OK:
---
## メモ

project-checks.sh への切り出し後も挙動が変わっていないことの固定。
