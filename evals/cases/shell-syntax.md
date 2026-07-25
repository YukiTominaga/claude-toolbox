---
id: shell-syntax
type: command
description: hooks / scripts / evals の全スクリプトが構文エラーを含まない
run: for f in hooks/*.sh scripts/*.sh evals/bin/*.sh .claude/checks.sh; do case "$(head -n1 "$f")" in *node*) node --check <"$f" || exit 1 ;; *) bash -n "$f" || exit 1 ;; esac; done
expect_exit: 0
---
## メモ

hook は壊れていても静かに fail-open するものが多く、構文エラーに気づきにくい。
`hooks/` には shebang が node のスクリプトが混在するため、拡張子ではなく shebang で
チェック方法を振り分けている(`.sh` だからと bash -n をかけると誤検知する)。
node 側は `.sh` を拡張子として受け付けないため、標準入力から流し込んでいる。
