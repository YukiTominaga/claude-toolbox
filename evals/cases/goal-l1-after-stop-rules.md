---
id: goal-l1-after-stop-rules
type: command
description: L1 は停止条件 3 層より後ろにある
run: evals/bin/hook-cases.sh goal-l1-after-stop-rules
expect_exit: 0
expect_output: ^OK:
---
## メモ

**順序の固定。無限ループの侵入検知器。**

L1 を停止条件より前に置くと、赤の間ずっと exit 2 でラウンド上限・無進捗の
どちらのチェックにも到達せず、goal-gate 自身が停止条件を持たない無限ループになる。
ラウンド上限 / 無進捗 の 2 経路すべてで、赤でも stalled に落ちることを確認する。
(経過時間の経路は `docs/spec/budget-removal.md` で撤廃した)
