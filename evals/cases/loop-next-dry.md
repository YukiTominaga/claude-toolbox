---
id: loop-next-dry
type: command
description: キューが枯れたら exit 3 でループを止められる
run: evals/bin/loop-cases.sh next-dry
expect_exit: 0
expect_output: ^OK:
---
## メモ

枯渇とエラーを区別できないと、無人ループが空回りし続ける。exit 3 は「止めてよい」の合図。
