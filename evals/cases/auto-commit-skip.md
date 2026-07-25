---
id: auto-commit-skip
type: command
description: 自動コミットが main / 差し戻し中 / 無変更 / マージ途中では動かない
run: evals/bin/loop-cases.sh auto-commit-skip
expect_exit: 0
expect_output: ^OK:
---
## メモ

自動コミットは黙って履歴を書き換える機能なので、動いてはいけない場面を明示的に固定する。特に main への直接コミットと、マージ/リベース途中の割り込みは実害が大きい。
