---
id: auto-commit-inner-loop
type: command
description: 往復中もコミットし、メッセージも通常どおり生成する
run: evals/bin/hook-cases.sh auto-commit-inner-loop
expect_exit: 0
expect_output: ^OK:
---
## メモ

差し戻しの往復中に素通ししていたため、内側ループの成果は round1 を除いて一度も
コミットされていなかった (done 判定のラウンドも stop_hook_active=true のため)。
無人実行では環境の回収でまるごと失われる。

当初は往復中だけメッセージ生成の Haiku を呼ばず定型文にフォールバックしていたが、
これも撤去した。往復ごとの課金を惜しんだ結果、内側ループが積むコミットの履歴だけが
`chore: 自動コミット` で埋まって読めなくなるのは割に合わない。
いまは往復中も通常ターンも同じ経路を通る。

claude スタブを置いたまま検証するのが要点。スタブを外すと「claude が PATH に
無いから定型になった」だけになり、テストがトートロジーになる。
