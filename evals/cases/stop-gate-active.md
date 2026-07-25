---
id: stop-gate-active
type: command
description: 差し戻しの往復中は素通しする
run: evals/bin/hook-cases.sh stop-gate-active
expect_exit: 0
expect_output: ^OK:
---
## メモ

stop-gate は goal-gate と違って停止条件を持たない (状態を書く先が無い)。
ここで素通しをやめると、テストが直らない限り無限に差し戻すゲートになる。
内側ループの L1 は goal-gate が担うので、ここを開ける必要はない。
