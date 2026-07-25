---
id: signal-add-numbering
type: command
description: signal-add.sh の採番・書式・エラー処理
run: evals/bin/loop-cases.sh signal-add-numbering
expect_exit: 0
expect_output: ^OK:
---
## メモ

`loop-add.sh` と同じ思想で、エージェントに markdown を直書きさせないためのラッパー。
採番がずれると同じ ID の signal が 2 つできて参照が壊れるので、連番だけは機械で保証する。

`README.md` を採番に数えないことを明示的に見ている(`S-*.md` にマッチさせているが、
将来 glob を緩めたときにここで落ちる)。

**本文を省いた呼び出しを含めているのは回帰テスト**。最初の実装は本文が空のとき
標準入力から読む親切機能を持っていたが、端末が繋がっていない文脈(eval・フック・
無人ループ)では `cat` を待って**永久にハングした**。無人ループで最も避けたい壊れ方なので、
引数だけを見る実装に変え、このケースで固定している。
