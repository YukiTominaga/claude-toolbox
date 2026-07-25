---
id: stop-gate-clean
type: command
description: 変更が無ければ検証しない
run: evals/bin/hook-cases.sh stop-gate-clean
expect_exit: 0
expect_output: ^OK:
---
## メモ

質問応答だけのセッションでテストスイートを回さないための最適化。
このポリシーは stop-gate に残し、project-checks.sh には移さない (checks-ignores-git を参照)。
