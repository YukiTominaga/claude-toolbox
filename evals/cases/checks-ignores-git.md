---
id: checks-ignores-git
type: command
description: project-checks.sh は git の状態を見ない
run: evals/bin/hook-cases.sh checks-ignores-git
expect_exit: 0
expect_output: ^OK:
---
## メモ

**最も踏みやすい退行の検出器。**

stop-gate の「変更が無ければスキップ」を project-checks.sh に持ち込むと、内側ループでは
L1 が全ラウンド消える。auto-commit と「feature ブランチでは自由にコミット」の運用により、
Stop 時点の作業ツリーは空が普通になるため。これはまさに今回直した欠陥そのもの。

「変更が無ければスキップ」は stop-gate 側のポリシーであり、切り出し先には移さない。
