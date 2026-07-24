---
id: loop-log-validation
type: command
description: 台帳が不正な result を弾き、正常時のみ 1 行追記する
run: evals/bin/loop-cases.sh log-reject
expect_exit: 0
expect_output: ^OK:
---
## メモ

台帳が壊れると実行履歴も予算判定も信用できなくなる。書き込みは必ずスクリプト経由にする。
