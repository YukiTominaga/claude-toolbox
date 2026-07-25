---
id: stop-gate-pushback-reset
type: command
description: stop_hook_active が false ならカウントをリセットする
run: evals/bin/hook-cases.sh stop-gate-pushback-reset
expect_exit: 0
expect_output: ^OK:
---
## メモ

false は「差し戻し連鎖が切れた」合図としてのみ使う。true が続く限りカウントを
持ち越すので、false が二度と来ない環境でも上限は効く。
