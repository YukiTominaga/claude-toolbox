---
id: loop-guard-budget
type: command
description: 実行ゲートは回数では止めず、実行を数え続ける
run: evals/bin/loop-cases.sh guard-budget
expect_exit: 0
expect_output: ^OK:
---
## メモ

**撤去した機構が戻ってこないことを固定するケース。**
かつては 1 日の実行回数 (`max_runs_per_day`) を上限として、超えたら `loop-guard.sh` が
`ok:false` で拒んでいた。撤廃した理由は `docs/spec/budget-removal.md` を参照
(対話セッションでは人が見ているため、回数で切っても暴走は防げず不便だけが残る)。

**`LOOP.md` に上限を書いた状態で検証する**。宣言を消して確かめると、
「宣言が無ければハードコードの既定値で止まる」という欠陥をすり抜けてしまう。
当日の start 行を 100 件積んでもゲートが素通しすることを見る。

止めないことと数えないことは別である。回数は `/crystal:loop status` の報告に使うため
**測り続ける**。記録はゲート自身が通過時に `{"event":"start"}` を書く形で行う
(かつて `loop-log.sh` 任せにしていた頃、エージェントが呼び忘れると記録が残らなかった)。
このケースは `loop-log.sh` を一度も呼ばずに start 行が積まれること、
結果行が start として二重に数えられないことも併せて確認している。
