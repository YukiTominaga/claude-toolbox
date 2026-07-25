---
id: stop-gate-active-red
type: command
description: 差し戻しの往復中でも赤なら差し戻す
run: evals/bin/hook-cases.sh stop-gate-active-red
expect_exit: 0
expect_output: ^OK:
---
## メモ

`stop_hook_active` は一度差し戻されると true に固定される。ここを素通しにすると、
goal.md の無いセッション (内側ループが動いていない普通の作業) では、一度差し戻された
時点で L1 が二度と走らない = 修正が赤を消したかを誰も確かめない。これが Q-7 で塞いだ穴。

無限ループを防ぐのは素通しではなく差し戻し回数の上限 (stop-gate-pushback-limit)。
