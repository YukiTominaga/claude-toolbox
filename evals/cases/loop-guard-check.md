---
id: loop-guard-check
type: command
description: 予算ゲートの --check が記録せず判定だけ返す
run: evals/bin/loop-cases.sh guard-check
expect_exit: 0
expect_output: ^OK:
---
## メモ

`/crystal:loop status` は状態を見るだけなので、予算を消費してはいけない。
ゲート自身が実行を数える設計にした以上、「数える呼び出し」と「見るだけの呼び出し」を
取り違えると、状態を確認するたびに予算が減る。
