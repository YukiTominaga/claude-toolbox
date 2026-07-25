---
id: loop-guard-check
type: command
description: 実行ゲートの --check が記録せず実績値だけ返す
run: evals/bin/loop-cases.sh guard-check
expect_exit: 0
expect_output: ^OK:
---
## メモ

`/crystal:loop status` は状態を見るだけなので、台帳に start 行を積んではいけない。
ゲート自身が実行を数える設計にした以上、「数える呼び出し」と「見るだけの呼び出し」を
取り違えると、状態を確認するたびに実行回数が水増しされ、台帳が実イテレーション数と食い違う。

回数で止めるのをやめた後もこのケースは要る。むしろ**回数が報告専用の値になったからこそ**、
それが実績を正しく表していることの重みが増した。`--check` の後で `runs_today` が
記録付きの呼び出しの分だけ増え、`--check` 自身では増えないことを両方向で見る。
