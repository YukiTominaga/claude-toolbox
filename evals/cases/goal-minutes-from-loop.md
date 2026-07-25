---
id: goal-minutes-from-loop
type: command
description: goal-gate は max_minutes / started_epoch を作らない
run: evals/bin/hook-cases.sh goal-minutes-from-loop
expect_exit: 0
expect_output: ^OK:
---
## メモ

**時間予算の撤廃が導線から復活しないことを固定するケース**(`docs/spec/budget-removal.md`)。

このケースは元々逆の主張(「LOOP.md の `max_minutes_per_run` が `goal.md` の既定値になる」)を
固定していた。撤廃に伴って反転させたが、**ケースが記録している失敗の型はそのまま生きている**:

> `hooks/goal-gate.sh` を直しても、`templates/goal.md` に該当フィールドが残っていれば
> `/crystal:goal` が作る goal.md 経由でモデルが書き戻し、撤廃が黙って無効化される。
> 実装と導線は同じ変更に含めなければならない。

そのため実装側(goal-gate が 2 フィールドを書き込まないこと)だけでなく、
`templates/goal.md` と `commands/goal.md` / `commands/loop.md` に記述が残っていないことも
同じケースで確認する。**解説コメントも対象**にしている(行を消してもコメントが残れば
モデルはそれを読んで書き戻せるため)。

`LOOP.md` に `max_minutes_per_run: 15` を置いたまま検証する。旧 LOOP.md を持つプロジェクトで
撤廃が効かなくなる経路を塞ぐため。
