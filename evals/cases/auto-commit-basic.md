---
id: auto-commit-basic
type: command
description: 自動コミットが feature ブランチで未追跡ファイルごと 1 コミットにまとめる
run: evals/bin/loop-cases.sh auto-commit-basic
expect_exit: 0
expect_output: ^OK:
---
## メモ

「気づいたら未コミット」を無くすのが目的なので、未追跡の新規ファイルを拾えることが要件そのもの。実際 LOOP.md を取りこぼした事故がきっかけ。
