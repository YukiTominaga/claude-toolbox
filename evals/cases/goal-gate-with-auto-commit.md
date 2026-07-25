---
id: goal-gate-with-auto-commit
type: command
description: goal-gate と auto-commit を同じターンで動かしても前進を停滞と誤判定しない
run: evals/bin/loop-cases.sh goal-gate-with-auto-commit
expect_exit: 0
expect_output: ^OK:
---
## メモ

**hook 単体の eval では捕まえられなかった不具合の再発防止。**

無進捗検知の署名が作業ツリー (`git diff HEAD` + `git status --porcelain`) だけを見ていたため、
「feature ブランチでは自由にコミットする」運用と auto-commit の導入によって
Stop 時点の作業ツリーが常に空になり、コミットを積み続けていても毎ラウンド同一の署名になった。
結果、前進しているのに 3 ラウンド目で `status: stalled` になりループが死んでいた。
このとき単体シナリオ 15 件はすべて PASS のままだった。

したがってこのケースの本質は「HEAD を署名に含めること」ではなく、
**hook 同士の組み合わせを通しで動かして検証すること**にある。
新しい Stop hook を足すときは、このシナリオにターンを足して確認すること。

検証しているターンの型は 3 つ:

- `committed` — ターン中に自分でコミットする(誤 stall はここで起きる)
- `dirty` — 変更を残して終え、auto-commit に任せる
- `none` — 何もしない(停滞。検知できることの確認)
