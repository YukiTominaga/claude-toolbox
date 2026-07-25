---
id: guard-cost
type: command
description: 実費の上限を台帳の cost 行の合計で判定する
run: evals/bin/loop-cases.sh guard-cost
expect_exit: 0
expect_output: ^OK:
---
## メモ

記事が「予算の上限が無いループ」を弱いループの徴候として名指ししている箇所への対応。
回数と時間による近似は残すが、**無人実行では実費で判定する**。

`loop-run.sh` が `claude -p --output-format json` の `total_cost_usd` を台帳に積み、
ゲートがその日の合計で判定する。失敗した実行のコストも積む: 積まないと、
失敗を繰り返すループが無限に課金できてしまう。

上限が未設定なら実費では判定しない(対話セッションではコストを観測できないため)。
他の日のコストを合計しないことも確認している。
