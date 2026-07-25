---
id: auto-commit-secret
type: command
description: 機密の可能性があるパスがあると自動コミットを中止して知らせる
run: evals/bin/loop-cases.sh auto-commit-secret
expect_exit: 0
expect_output: ^OK:
---
## メモ

git add -A 相当で未追跡ごと拾う設計の引き換えになっている安全策。ここが外れると .env が黙ってコミットされるため、最優先で守る。
