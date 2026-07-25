---
id: loop-guard-fail-open
type: command
description: LOOP.md が無いプロジェクトでは判定を素通しする
run: evals/bin/loop-cases.sh guard-open
expect_exit: 0
expect_output: ^OK:
---
## メモ

ループ契約を導入していないプロジェクトで既存の作業を妨げないこと(fail-open の維持)。
