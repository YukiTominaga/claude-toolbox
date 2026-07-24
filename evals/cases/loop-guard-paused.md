---
id: loop-guard-paused
type: command
description: LOOP.md が paused の間は実行しない
run: evals/bin/loop-cases.sh guard-paused
expect_exit: 0
expect_output: ^OK:
---
## メモ

人間が止めた意思をループが無視しないこと。
