---
id: goal-no-progress-sees-untracked
type: command
description: 未追跡ファイルへの追記を前進として数える
run: evals/bin/hook-cases.sh goal-no-progress-sees-untracked
expect_exit: 0
expect_output: ^OK:
---
## メモ

`git status --porcelain` は未追跡ファイルの**名前しか出さない**ため、既存の未追跡ファイルに
追記しても署名が変わらず「進んでいない」と判定される。

通常運転では auto-commit が毎ラウンドコミットして HEAD が動くので表面化しないが、
auto-commit が効かない構成(main ブランチ、機密パス検出で中止)では、
**前進しているのに stalled になる**。

内容の取り込みには `cksum` を使う。`shasum` は perl 同梱、`sha1sum` は GNU 専用で、
どちらか一方に依存すると別プラットフォームで静かに壊れる。

`xargs` は入力が空だと引数なしで `cksum` を起動し、`cksum` は標準入力を読みにいく。
このフックでは stdin が既に読み切られているため**実測ではハングしない**が、それは
stdin が何であるかに依存した偶然でしかない。空かどうかを先に見て挙動を切り離している
(`signal-add.sh` では同じ形が実際にハングした)。

「何もしなければ従来どおり停滞を検知する」ことも同じシナリオで確認している。
感度を上げた結果として停止条件 4 が効かなくなっていないか、が本質的な確認点。
