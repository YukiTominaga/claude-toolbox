---
id: goal-no-progress-ignores-ledger
type: command
description: ループ自身の記帳 (.claude/loop/) を前進と誤認しない
run: evals/bin/hook-cases.sh goal-no-progress-ignores-ledger
expect_exit: 0
expect_output: ^OK:
---
## メモ

**独立検証エージェントが捕まえた回帰の再発防止。**

判定履歴を `~/.claude/logs/goal-gate.jsonl` から `.claude/loop/judge-log.jsonl` に
移したところ、goal-gate が毎ラウンド書き込むそのファイルが無進捗検知の署名に入り、
**完全に停滞していても署名が毎回変わって stalled にならなくなった**。停止条件 4 が丸ごと死ぬ。

`.claude/loop/` は `.gitignore` 対象にする運用だが、それに依存すると
gitignore していないプロジェクトで静かに壊れる。署名計算側で pathspec 除外する。

同じ根の問題が既に 2 回起きている(auto-commit が作業ツリーを空にする →
署名に HEAD を追加 / auto-commit がコミットする → 判定器に git log を追加)。
**「作業ツリーを覗く仕組み」は、ループ自身の書き込みで必ず汚染される**と考えること。
