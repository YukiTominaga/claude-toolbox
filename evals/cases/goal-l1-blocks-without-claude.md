---
id: goal-l1-blocks-without-claude
type: command
description: claude 不在でも L1 が赤なら差し戻す
run: evals/bin/hook-cases.sh goal-l1-blocks-without-claude
expect_exit: 0
expect_output: ^OK:
---
## メモ

**挿入位置が `command -v claude` より前であることの証明。**

claude が PATH に無ければ goal-gate は本来 fail-open で exit 0 にしかならない。
そこで exit 2 が返るのは、判定器より手前で L1 が赤を出したとき以外にありえない。
判定器の後ろに移すとこのケースが落ちる。
