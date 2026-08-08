#!/bin/bash
# record-subagent-edits.sh — サブエージェントによるコード変更を SubagentStop で記録する
#
# verify-gate.sh / change-gate.sh の判定材料はメインセッションの transcript だが、
# そこにはサブエージェントの起動 (Task / Agent の tool_use) しか現れず、
# サブエージェントが中でどのファイルを編集したかは載らない。このままでは
# 「実装をサブエージェントに委譲する」だけで独立検証の強制が丸ごと沈黙する。
#
# ここで「コードを変更したサブエージェントがいた」事実だけを状態ファイルに残し、
# Stop 側のゲートが読む。記録専用で、exit 2 はしない (fail-open)。
set -u

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session_id" ] || exit 0

tp=$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null)
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi

. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"

# 編集ツールでコードファイル (実装またはテスト) に触れたかだけを見る。
# spec / 設定は verify-gate と同じ理由で数えない (仕様のステータス更新で
# 再検証を要求すると抜けられなくなる)。Bash 経由の書き換えも数えない
# (リダイレクトを変更とみなすとログ出力のたびに再検証を要求することになる)。
# verifier / spec-critic は編集ツールを持たないため、自然に記録対象から外れる。
edited=$(jq -Rr --arg code "$CODE_RE" --arg config "$CONFIG_RE" --arg spec "$SPEC_RE" \
  --arg root "$project_dir" '
  fromjson? // empty
  | select(.type=="assistant") | .message.content[]?
  | select(.type=="tool_use")
  | select(.name=="Write" or .name=="Edit" or .name=="MultiEdit" or .name=="NotebookEdit")
  | (.input.file_path // "") | ltrimstr($root + "/")
  | select(test($spec) | not)
  | select(test($config) | not)
  | select(test($code))' "$tp" 2>/dev/null | head -n 1)
[ -n "$edited" ] || exit 0

dir=$(crystal_state_dir)
mkdir -p "$dir" 2>/dev/null || exit 0
# セッションを跨いで残った古い状態は使い道が無いので、書くついでに掃除する
find "$dir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null
printf '%s\n' "$edited" >>"$(subagent_edits_file "$session_id")" 2>/dev/null
exit 0
