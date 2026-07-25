---
id: checks-none
type: command
description: チェックが無いプロジェクトを赤にしない
run: evals/bin/hook-cases.sh checks-none
expect_exit: 0
expect_output: ^OK:
---
## メモ

npm も pytest も無いリポジトリ (crystal 自身がそう) で内側ループが止まらないこと。
