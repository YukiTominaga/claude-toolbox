---
id: goal-l1-round-consumed
type: command
description: 赤い L1 でもラウンドを消費し、上限で止まる
run: evals/bin/hook-cases.sh goal-l1-round-consumed
expect_exit: 0
expect_output: ^OK:
---
## メモ

差し戻しが有限であることの確認。goal-l1-after-stop-rules が「停止条件に到達すること」を
見るのに対し、こちらは「実際に回して必ず終わること」を見る。
