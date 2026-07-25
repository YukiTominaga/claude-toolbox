---
id: goal-l1-after-stop-rules
type: command
description: L1 は停止条件 4 層より後ろにある
run: evals/bin/hook-cases.sh goal-l1-after-stop-rules
expect_exit: 0
expect_output: ^OK:
---
## メモ

**順序の固定。無限ループの侵入検知器。**

L1 を停止条件より前に置くと、赤の間ずっと exit 2 でラウンド上限・予算・無進捗の
どのチェックにも到達せず、goal-gate 自身が停止条件を持たない無限ループになる。
ラウンド上限 / 予算 / 無進捗 の 3 経路すべてで、赤でも stalled に落ちることを確認する。
