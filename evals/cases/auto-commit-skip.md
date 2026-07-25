---
id: auto-commit-skip
type: command
description: 自動コミットが main / 無変更 / マージ途中では動かない
run: evals/bin/hook-cases.sh auto-commit-skip
expect_exit: 0
expect_output: ^OK:
---
## メモ

自動コミットは黙って履歴を書き換える機能なので、動いてはいけない場面を明示的に固定する。特に main への直接コミットと、マージ/リベース途中の割り込みは実害が大きい。

**「差し戻しの往復中」はこの一覧から外した**。内側ループ (goal-gate) は毎ラウンド差し戻すため、
往復中に素通しすると done 判定のラウンドまで含めて一度もコミットされず、無人実行では
成果がまるごと失われる。往復中の挙動は `auto-commit-inner-loop` が固定している。
