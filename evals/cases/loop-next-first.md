---
id: loop-next-first
type: command
description: discover が先頭の未着手項目とメタデータを取り出す
run: evals/bin/loop-cases.sh next-first
expect_exit: 0
expect_output: ^OK:
---
## メモ

外側ループの取り出し順が「常に先頭の未着手」で決定的であることを固定する。ここが揺れるとループの再現性が失われる。
