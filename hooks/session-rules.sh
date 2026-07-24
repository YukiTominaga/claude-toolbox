#!/bin/bash
# session-rules.sh — SessionStart で rules/*.md をセッションコンテキストに注入する。
# プラグインを有効化するだけでルールが適用される(外部の CLAUDE.md 参照は不要)。
# 出力は hookSpecificOutput.additionalContext の JSON。失敗時は何も注入しない (fail-open)。
set -u

dir="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/rules"
[ -d "$dir" ] || exit 0

content=$(cat "$dir"/*.md 2>/dev/null)
[ -n "$content" ] || exit 0

printf '%s' "$content" | jq -Rs '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("以下は crystal プラグインのルール。このセッションで常に適用すること:\n\n" + .)
  }
}' 2>/dev/null || exit 0
