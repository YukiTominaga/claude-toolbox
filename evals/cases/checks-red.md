---
id: checks-red
type: command
description: project-checks.sh は赤なら exit 1 で失敗内容を返す
run: evals/bin/hook-cases.sh checks-red
expect_exit: 0
expect_output: ^OK:
---
## メモ

失敗したチェック名とコマンド出力を返さないと、差し戻されたエージェントが何を直せばよいか
分からない。exit code だけでなく中身も検証する。
