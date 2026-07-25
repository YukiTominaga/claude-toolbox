---
id: guard-cost-never-blocks
type: command
description: 金額ではループを止めず、実費を判定材料にも使わない
run: evals/bin/loop-cases.sh guard-cost-never-blocks
expect_exit: 0
expect_output: ^OK:
---
## メモ

**撤去した機構が戻ってこないことを固定するケース。**

以前は `max_cost_usd_per_day` を上限として、台帳の cost 行の合計がそれを超えたら
`loop-guard.sh` が `ok:false` を返して実行を拒んでいた。これを撤去した理由:

- サブスクリプション(Max 等)では `total_cost_usd` はトークン数から計算した参考値に
  すぎず追加課金も発生しない。金額を上限にしても意味のある歯止めにならない
- それでいて**実際に動作を止めていた**。無人ループが `error_max_budget_usd` で
  打ち切られ、実装は済んでいるのに独立検証と記帳が未了のまま `failed` になった実績がある
- `LOOP.md` が「無人化には `max_cost_usd_per_day` を設定済みであること」を昇格条件に
  掲げる一方、同じファイルが「空のままにする」と指示しており、**永久に満たせない条件**だった

歯止めは回数 (`max_runs_per_day`) とターン数 (`max_turns_per_run`) が担う。
どちらも課金形態に依存しない。経過時間 (`max_minutes_per_run`) も歯止めの 1 つだったが、
別途撤廃した(`docs/spec/budget-removal.md` — 対話セッションでは人が見ているため
時間で切っても暴走は防げず、作業を切られる不便だけが残る)。

このケースは、古い `LOOP.md` に `max_cost_usd_per_day` が残っていても、
台帳に大きな cost 行が積まれていても、ゲートが**素通しする**ことを確認する。
併せて出力に `cost_today_usd` / `cost_remaining_usd` が現れないことも見る
(判定材料として復活させたら落ちる)。実費の**記録**は
`loop-run.sh` 側で続いており、それは `run-normal` が固定している。
