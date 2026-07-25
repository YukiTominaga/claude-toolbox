---
id: stop-gate-pushback-limit
type: command
description: 差し戻しは連鎖内で 3 回まで。4 回目は素通しして知らせる
run: evals/bin/hook-cases.sh stop-gate-pushback-limit
expect_exit: 0
expect_output: ^OK:
---
## メモ

stop-gate は goal-gate と違って goal.md を読まないので、停止条件はこの回数上限だけ。
赤が直らないまま無限に差し戻すのを防ぐ。上限に達したら L1 を実行せずに素通しし、
黙って通さないよう systemMessage で人間に知らせる。
