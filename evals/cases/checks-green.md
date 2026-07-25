---
id: checks-green
type: command
description: project-checks.sh は緑なら 3 つのチェックを実行して exit 0
run: evals/bin/hook-cases.sh checks-green
expect_exit: 0
expect_output: ^OK:
---
## メモ

切り出しの契約。呼び出し元 (stop-gate / goal-gate) はこの exit code だけを見る。
