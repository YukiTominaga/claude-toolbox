---
id: auto-commit-ignores-ledger
type: command
description: ループ自身の記帳は除外しつつ、作業は必ずコミットする
run: evals/bin/hook-cases.sh auto-commit-ignores-ledger
expect_exit: 0
expect_output: ^OK:
---
## メモ

**2 つの退行を同時に押さえている。**

1. **記帳をコミットしてはいけない**。`.claude/loop/` と `.claude/goal.md` はループの
   帳簿であってエージェントの作業ではない。コミットすると HEAD が毎ラウンド動き、
   goal-gate の無進捗検知が「前進している」と誤認して停止条件 4 が丸ごと死ぬ。
2. **除外の書き方を間違えると何もコミットしなくなる**。`git add -A -- . ':(exclude)...'`
   は、対象が `.gitignore` 済みだと「The following paths are ignored」で **exit 1** になる。
   auto-commit は `|| exit 0` で受けているので、**無言で一切コミットしなくなる**。
   推奨構成(`.claude/loop/` を gitignore)ほど確実に踏むので、(2) のケースで固定する。
   正しい実装は `git add -A` の後に `git reset -- <記帳のパス>` で外すこと。

シナリオ (1) は記帳が追跡されている構成、(2) は gitignore されている構成。
両方で「作業がコミットされること」を確認する。
