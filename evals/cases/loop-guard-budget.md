---
id: loop-guard-budget
type: command
description: 予算ゲート自身が実行を数え、上限に達したら止める
run: evals/bin/loop-cases.sh guard-budget
expect_exit: 0
expect_output: ^OK:
---
## メモ

予算はトークンではなく実行回数で表現する。無人ループの暴走を止める最後の砦。

当初は `loop-log.sh` が書いた台帳の行を数えていたが、その呼び出しはエージェント任せ
(`/crystal:loop next` の最終手順)だったため、**途中で失敗・中断・忘却すれば予算は
永遠に減らなかった**。最後の砦が、守られる当人の善意に依存していた。
そこでゲート自身が通過時に `{"event":"start"}` を記録する方式に変えた。

このケースは `loop-log.sh` を**一度も呼ばずに** guard だけを繰り返し、
上限で止まることを検証している(自己申告への逆戻りを防ぐため)。
併せて、結果行が start として二重に数えられないことも確認している。
