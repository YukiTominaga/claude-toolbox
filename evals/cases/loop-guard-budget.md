---
id: loop-guard-budget
type: command
description: 当日の実行回数が上限に達したら実行を止める
run: evals/bin/loop-cases.sh guard-budget
expect_exit: 0
expect_output: ^OK:
---
## メモ

予算はトークンではなく実行回数で表現する。無人ループの暴走を止める最後の砦。
