#!/bin/bash
# session-learnings.sh — プロジェクトの .claude/learnings.md をセッション開始時に注入する
#
# rules/learning.md と /crystal:learn は知見を .claude/learnings.md に書き溜めるが、
# 読み込む導線がどこにも無いため、次のセッションでは参照されないままだった
# (書くだけで回収されない)。ここでコンテキストに載せて回収経路を閉じる。
set -u

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0

FILE=".claude/learnings.md"
[ -f "$FILE" ] || exit 0

# 際限なく増えるファイルなので末尾だけを載せる(新しいエントリほど下にある)
MAX_BYTES=8000

total=$(wc -c <"$FILE" 2>/dev/null | tr -d ' ')
case "$total" in '' | *[!0-9]*) exit 0 ;; esac
[ "$total" -gt 0 ] || exit 0

content=$(tail -c "$MAX_BYTES" "$FILE" 2>/dev/null)
if [ "$total" -gt "$MAX_BYTES" ]; then
  # 先頭行はマルチバイト文字の途中で切れている可能性があるため、awk に渡す前に必ず落とす
  # (壊れたバイト列を渡すと awk が multibyte conversion failure で停止する)
  content=$(printf '%s\n' "$content" | tail -n +2)
  # 途中で切れたエントリを渡さないよう、最初の見出し行から始める
  trimmed=$(printf '%s\n' "$content" | awk '/^## / { f = 1 } f')
  [ -n "$trimmed" ] && content="$trimmed"
  note=" (全 ${total} バイトのうち末尾のみ。全文は ${FILE})"
else
  note=""
fi

[ -n "$content" ] || exit 0

printf '%s' "$content" | jq -Rs --arg note "$note" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: (
      "以下はこのプロジェクトで蓄積された知見 (.claude/learnings.md)" + $note +
      "。同じ問題を繰り返さないために参照すること。新たな知見を得たら同じ書式で追記すること:\n\n" + .
    )
  }
}' 2>/dev/null || exit 0
