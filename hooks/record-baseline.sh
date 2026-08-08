#!/bin/bash
# record-baseline.sh — セッション開始時点の HEAD を SessionStart で記録する
#
# change-gate / verify-gate / stop-gate は「何が変わったか」を判定材料にするが、
# 比較の基点が常に HEAD だと、応答を終える前に git commit するだけで差分が消え、
# 3 つのゲートが全て沈黙する (敵対的レビューで実証された迂回経路)。
# ここでセッション開始時点の HEAD を状態ファイルに固定し、Stop 側のゲートは
# 「ベースラインからの差分」(commit 済みの変更を含む) で判定する。
#
# 記録専用で、既に記録があれば上書きしない (resume / compact の SessionStart で
# 基点が進むと、そのセッションで commit 済みの変更が判定から漏れる)。
# 記録できない環境では何もしない = ゲートは従来どおり HEAD 比較 (fail-open)。
set -u

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session_id" ] || exit 0

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"

head=$(git rev-parse HEAD 2>/dev/null) || exit 0 # 初回コミット前は基点を作れない
[ -n "$head" ] || exit 0

dir=$(crystal_state_dir)
mkdir -p "$dir" 2>/dev/null || exit 0
# セッションを跨いで残った古い状態は使い道が無いので、書くついでに掃除する
find "$dir" -type f -mtime +7 -exec rm -f {} + 2>/dev/null

f=$(session_baseline_file "$session_id")
[ -f "$f" ] || printf '%s\n' "$head" >"$f" 2>/dev/null
exit 0
