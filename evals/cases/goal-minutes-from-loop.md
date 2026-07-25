---
id: goal-minutes-from-loop
type: command
description: LOOP.md の max_minutes_per_run が goal.md の予算の既定値になる
run: evals/bin/hook-cases.sh goal-minutes-from-loop
expect_exit: 0
expect_output: ^OK:
---
## メモ

**宣言した予算が機械的に効くことを固定するケース。**

README は `max_minutes_per_run` を「goal-gate が停止条件として効かせる」と説明していたが、
`hooks/goal-gate.sh` は LOOP.md を一度も読まず、既定値 60 をハードコードしていた
(`grep -c "LOOP.md" hooks/goal-gate.sh` → 0)。LOOP.md に 30 と書いても内側ループは
60 分回り、宣言した値が実際に入るのはモデルが `commands/goal.md` の指示に従って
手で写したときだけ = **停止条件 4 層のうち「予算」層だけが人手依存**だった。

併せて `templates/goal.md` から `max_minutes: 60` の行を削除している。frontmatter に
キーが存在すると `ensure_field` は上書きしないため、テンプレートに値が書かれている限り
LOOP.md の宣言は永久に効かない。**実装だけ直しても導線側で無効化される**という形の
穴だったので、両方を同じ変更に含めている。

LOOP.md が無いプロジェクトでは従来どおり 60 になることも同時に固定する
(LOOP.md を前提にすると、ループを使わずに `/crystal:goal` だけ使う構成が壊れるため)。
