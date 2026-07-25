---
id: loop-add-numbering
type: command
description: キューへの追記が正しく採番され、discover 側がその行を読める
run: evals/bin/loop-cases.sh add-numbering
expect_exit: 0
expect_output: ^OK:
---
## メモ

採番をエージェントに任せると番号が衝突・重複する。キューの ID が壊れると台帳と
突き合わせられなくなるため、採番はスクリプトに閉じ込めてここで固定する。
`GH-<n>`(Issue 番号)を採番に混ぜないことと、追記した行を `loop-next.sh` が
そのまま読めること(書式の後方互換)も同時に守っている。
