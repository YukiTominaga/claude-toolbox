---
id: goal-judge-broken
type: command
description: 判定器が壊れてもループを止めない (fail-open)
run: evals/bin/hook-cases.sh goal-judge-broken
expect_exit: 0
expect_output: ^OK:
---
## メモ

**判定器 (L4) の経路を課金せずに踏むためのケース。**

これまで eval は `PATH` から claude を外すことで判定器を回避しており、
`command -v claude` より後ろのコードを **1 行も踏んでいなかった**。
`CRYSTAL_JUDGE_CMD` で判定器を差し替えられるようにしたことで、
met / unmet / 壊れた出力 の 3 経路を決定的に検証できる。

スタブは `claude -p --output-format json` と同じ形
(`{..., "result": "<JSON文字列>", "total_cost_usd": N}`)を返す。
本物と同じ形を返させることが要点で、独自形式にするとスタブだけ通ってしまう。
