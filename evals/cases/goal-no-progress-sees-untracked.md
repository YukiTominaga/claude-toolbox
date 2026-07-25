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

**`git ls-files` には `-z` を必ず付ける。** 既定 (`core.quotePath=true`) では非 ASCII の
パスが C クォートされて出力されるため、改行区切りで受け取ると実在しないパスになり、
`cksum` が失敗して内容が署名に入らない。**日本語名のファイルで前進しているのに stalled になる。**
このマシンはグローバル設定が `core.quotePath=false` で症状が出ないので、
fixture 側で `core.quotePath true` に固定して再現させている
(独立検証がこの「私の環境でだけ動く」欠陥を捕まえた)。

空判定を先に行うのは、`xargs` が空入力でもコマンドを起動する実装 (GNU) があり、
引数なしの `cksum` が標準入力を読みにいくため。macOS/BSD は空入力では起動せず、
`-r` は GNU 由来で BSD では no-op として受理される。どちらでも同じ挙動にする。

「何もしなければ従来どおり停滞を検知する」ことも同じシナリオで確認している。
感度を上げた結果として停止条件 4 が効かなくなっていないか、が本質的な確認点。
