---
id: goal-gate-budget
type: command
description: 経過時間では stalled にならない
run: evals/bin/hook-cases.sh goal-budget
expect_exit: 0
expect_output: ^OK:
---
## メモ

**経過時間による停止の撤廃を固定するケース**(`docs/spec/budget-removal.md`)。

かつては停止条件 3 として「経過が `max_minutes` 以上なら `status: stalled`」があった。
撤廃した理由は、対話セッションでは人が見ているため時間で切っても暴走は防げず、
作業を途中で切られる不便だけが残ったこと。無人実行の歯止めは `scripts/loop-run.sh` が
定数として持つ `--max-turns` が担う。

10 年前に始めた `started_epoch` と `max_minutes: 1` を**明示的に置いた** goal.md を与える。
撤廃前の実装や、残骸フィールドを読んで止める実装ならここで `stalled` になって落ちる。
`status: active` のままラウンドが進み、停止条件を抜けて L1 に到達すること
(`calls_count` が 1)まで見ているので、「時間で止めない」を素通しでごまかせない。
