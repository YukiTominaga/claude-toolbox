---
id: log-recent
type: command
description: loop-log.sh --recent が結果行だけを新しい順に返す
run: evals/bin/loop-cases.sh log-recent
expect_exit: 0
expect_output: ^OK:
---
## メモ

台帳を「書かれるだけ」で終わらせないための読み口。イテレーションの冒頭でこれを読むことで、
前回 blocked / failed になった理由を踏まえてから着手できる(同じ壁に二度当たらない)。

`start` 行を混ぜないことを明示的に見ている。start は予算の集計用であって作業の履歴ではなく、
混ざると「直近 5 件」がゲートの記録で埋まって肝心のメモが押し出される。

逆順は `awk` で行っている。`tail -r` は BSD 専用、`tac` は GNU 専用で、
どちらか片方に依存すると別プラットフォームで静かに順序が壊れる。
