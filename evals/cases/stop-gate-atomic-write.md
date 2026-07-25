---
id: stop-gate-atomic-write
type: command
description: カウントの更新は置換で行い、一時ファイルを残さない
run: evals/bin/hook-cases.sh stop-gate-atomic-write
expect_exit: 0
expect_output: ^OK:
---
## メモ

差し戻し上限はカウント (`.claude/loop/stop-gate-pushback`) が読めることだけに依存している。
読めなければ `case '' | *[!0-9]*) count=0` で 0 に丸められ、上限に到達しなくなる。
直書き (`printf > "$STATE"`) は「空にする」と「書く」の 2 段階なので、並行するフックが
その隙間で読むと 0 に丸まる。一時ファイルへ書いてから `mv` で被せれば、読み手は
常に旧値か新値のどちらかを見る。

inode の比較は「上書きではなく置換で書かれた」ことの外形的な証拠として使っている。
ただし inode が変わるだけでは足りない — `rm` してから作り直す実装も inode は変わるが、
ファイルが存在しない窓が開いて読み手が `cat` に失敗する。置換先を unlink しないことは
`docs/spec/Q-19.md`「設計上の決定」で縛り、コードレビューで見る。

一時ファイルの残骸を見る assertion は**退行ガードでミューテーション対象ではない**。
直書き実装には一時ファイルが無いので自明に成立してしまう。
