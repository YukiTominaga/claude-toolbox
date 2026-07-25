---
id: run-records-abort
type: command
description: 途中で打ち切られたイテレーションを台帳に残す
run: evals/bin/loop-cases.sh run-records-abort
expect_exit: 0
expect_output: ^OK:
---
## メモ

**実運用で踏んだ穴の再発防止。**

無人で回したところ日次の実費上限に達し、`error_max_budget_usd` でイテレーションが
打ち切られた。エージェントは手順 7(記帳)まで到達できず、
**台帳には cost 行しか残らなかった**。次の周回は手順 0 で台帳を読むので、
「前回 Q-7 が途中で切れた」ことを知る手段が無くなる。

その実費上限そのものは後に撤去した(`guard-cost-never-blocks` を参照)。
いま打ち切りを起こしうるのは `max_turns_per_run` によるターン上限なので、
スタブが返す subtype も `error_max_turns` にしてある。**打ち切りの理由が何であれ
台帳に残す**というのがこのケースの本体で、そこは変わらない。

打ち切られた場合は `loop-run.sh` が代わりに `failed` を記録する。
id はキュー先頭を実行前に控えておいたものを使う(`loop-next.sh` は読み取りのみ)。
エージェントが自分で記録できていた場合は二重に書かない。
