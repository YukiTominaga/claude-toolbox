---
id: inner-loop-l1
type: command
description: 内側ループの全ラウンドで L1 が走り、コミットも積まれる
run: evals/bin/hook-cases.sh inner-loop-l1
expect_exit: 0
expect_output: ^OK:
---
## メモ

**hook 3 本を通しで回す合成シナリオ。**

1 ターン = stop-gate → goal-gate → auto-commit。round1 は stop_hook_active=false、
差し戻された 2 ラウンド目以降は true になる。往復ラウンドで L1 の実行がちょうど 1 回分
だけ増えることを数で確認する (0 なら床が抜けている、2 回分なら二重実行)。

新しい Stop hook を足すときは、このシナリオにもターンを足すこと。
