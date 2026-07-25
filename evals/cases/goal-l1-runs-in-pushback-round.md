---
id: goal-l1-runs-in-pushback-round
type: command
description: 往復ラウンドでも L1 が走り、二重実行にならない
run: evals/bin/hook-cases.sh goal-l1-runs-in-pushback-round
expect_exit: 0
expect_output: ^OK:
---
## メモ

**今回直した欠陥の直接の再発防止。**

stop_hook_active は一度差し戻されると true に固定される。stop-gate と auto-commit は
これで素通しするため、内側ループでは L1 検証が全ラウンド抜けていた (Haiku 判定だけが
検証になっていた)。goal-gate 側で無条件に走らせることで塞いでいる。

同じラウンドで stop-gate が走らないことも同時に確認する = 二重実行にならない。
