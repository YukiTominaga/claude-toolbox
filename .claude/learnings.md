# Learnings

## 2026-07-22: plugin の commands/ は details 上 Skills としてカウントされる

`claude plugin details crystal@yuki-local` は Skills (13) と表示するが、これは
skills/ の 11 個 + commands/ の 2 個(learn, spec)の合算。現行の Claude Code では
コマンドが user-invocable skill に統合されているため。commands/ の数が合わないと
慌てないこと。呼び出し名は `crystal:spec` / `crystal:learn`。

## 2026-07-22: hooks.json の ${CLAUDE_PLUGIN_ROOT} はダブルクォート必須

hooks.json の command は `"${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh"` のように
値の中でダブルクォートで囲む。パスに空白等が入った場合のシェル解釈対策で、
クォートなしだと展開後に壊れる可能性がある。
