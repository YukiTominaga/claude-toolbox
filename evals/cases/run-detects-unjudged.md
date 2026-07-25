---
id: run-detects-unjudged
type: command
description: 判定器を通らなかったイテレーションを検出して failed に落とす
run: evals/bin/loop-cases.sh run-detects-unjudged
expect_exit: 0
expect_output: ^OK:
---
## メモ

**記事の "don't let an agent self-verify" を機械で担保するための検出器。**

無人で 1 回回したところ、`.claude/goal.md` が `status: done` かつ `round: 0` で終わり、
判定履歴が 1 行も作られなかった。= goal-gate が一度も判定しておらず、内側ループが
丸ごと素通しされていた。作業自体は完了していたが、検証は自己採点だけだった。

`commands/loop.md` に「goal.md は active で作り、自分で done にしない」と書いたが、
**指示は強制ではない**。無人実行では判定履歴の増分を照合し、
「done と報告されたのに判定が 0 回」なら失敗として扱う。

台帳に `failed` を残すのは、次のイテレーションが手順 0 でそれを読むため。
検出して終わりにせず、次の周回に伝える。
