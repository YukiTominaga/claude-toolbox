---
id: stop-gate-no-state-dir
type: command
description: カウントを永続化できない環境では往復中だけ素通しする
run: evals/bin/hook-cases.sh stop-gate-no-state-dir
expect_exit: 0
expect_output: ^OK:
---
## メモ

`.claude/loop` に書けないと差し戻し回数を数えられない。数えられないまま差し戻すと
上限が効かず無限ループになるので、往復中 (stop_hook_active: true) は従来どおり素通しする。
初回停止は 1 回で止まるので検証する = 書けない環境でも L1 の床が完全には消えない。
