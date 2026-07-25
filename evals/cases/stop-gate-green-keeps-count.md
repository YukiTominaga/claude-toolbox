---
id: stop-gate-green-keeps-count
type: command
description: 緑のラウンドでは差し戻しカウントを減らさない
run: evals/bin/hook-cases.sh stop-gate-green-keeps-count
expect_exit: 0
expect_output: ^OK:
---
## メモ

独立検証が指摘した回帰ガードの欠落。`docs/spec/Q-7.md` の AC-4 が明示的に要求していた
性質だが、実装のコメントでしか守られておらず eval が無かった。

減らしてしまうと、赤 → 緑 → 赤 → 緑 と往復するあいだ上限に到達せず、
差し戻しの歯止めが実質無効になる。赤緑を往復させて上限に到達することまで見ている。
