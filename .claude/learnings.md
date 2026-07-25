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

## 2026-07-25: macOS には timeout コマンドが無い

`timeout` は GNU coreutils 同梱で、macOS には**存在しない**。hook から
`timeout N claude -p ...` と書くと 127 で必ず失敗し、`|| { warn; exit 0; }` の
fail-open に落ちる。goal-gate の Haiku 判定はこれで**丸ごと死んでいた**が、
fail-open なので誰も気づかなかった。`command -v timeout || command -v gtimeout`
で分岐し、無ければ付けずに実行する(hooks.json の timeout がバックストップ)。

## 2026-07-25: auto-commit があると判定器から作業が見えなくなる

goal-gate が judge に渡していたのは `git status --short` だけだった。auto-commit が
ターンごとに作業ツリーを空にするため、judge には「何もしていない」ように見え、
完了しているのに未達と誤判定する(実測の理由: 「smoke-a.txt が git status に
表示されていないため確認できない」)。判定材料に `git log --name-status` を足して解決。
無進捗検知の署名に HEAD を含める必要があったのと**まったく同じ根**の問題で、
auto-commit を足すと「作業ツリーを覗く仕組み」がすべて壊れる、と一般化できる。

## 2026-07-25: Stop hook は登録順に全部走る / stop_hook_active は true に固定される

実測(一時 dir に 2 本登録して `claude -p`): 先頭の Stop hook が exit 2 しても
後続の Stop hook は走る。`stop_hook_active` は初回 false、差し戻し後は true に固定。
この 2 つは公式ドキュメントに無く、hook を偽の入力で起動する eval では検知できない。
`scripts/loop-smoke.sh` がこの契約を実 Claude Code 経由で確かめる。
