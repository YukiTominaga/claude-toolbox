---
id: auto-commit-inner-loop
type: command
description: 往復中もコミットし、そのときだけ judge を呼ばない
run: evals/bin/hook-cases.sh auto-commit-inner-loop
expect_exit: 0
expect_output: ^OK:
---
## メモ

差し戻しの往復中に素通ししていたため、内側ループの成果は round1 を除いて一度も
コミットされていなかった (done 判定のラウンドも stop_hook_active=true のため)。
無人実行では環境の回収でまるごと失われる。

コミットはするがメッセージ生成の Haiku は呼ばない、という分岐を claude スタブで検証する。
スタブを置かないと「claude が PATH に無いから定型になった」だけになり、テストが
トートロジーになる。
