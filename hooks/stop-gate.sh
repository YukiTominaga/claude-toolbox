#!/bin/bash
# stop-gate.sh — 完了宣言時の検証ゲート
# Claude が応答を終えようとしたとき、リポジトリに変更があれば L1 検証を実行し、
# 失敗していれば exit 2 で差し戻す。検証の中身は scripts/project-checks.sh にある。
#
# ゴール(.claude/goal.md)が動いているセッションでは goal-gate が毎ラウンド同じ検証を行うが、
# **このフックは goal.md を読まない**。双方が同じファイルを別々に解釈してズレると
# 「どちらも検証しない」に倒れるため。読まなければ最悪でも「二重実行(無駄)」に倒れる。
set -u

# --- プラグインルートの解決は cd より前に行う ---
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

input=$(cat)

# --- 再帰防止: このフックによる差し戻し後の再停止では素通しする ---
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# --- git 管理下でなければ対象外 ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --- 変更がなければゲート不要(質問応答セッション等) ---
if git diff --quiet HEAD 2>/dev/null \
  && git diff --cached --quiet 2>/dev/null \
  && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  exit 0
fi

CHECKS="$ROOT/scripts/project-checks.sh"
[ -x "$CHECKS" ] || exit 0

if ! failed=$("$CHECKS" 2>&1); then
  printf '検証ゲート失敗。以下のエラーを修正するまで完了と報告しないこと。修正後は実際のコマンド出力を根拠として提示すること。\n%s\n' "$failed" >&2
  exit 2
fi

exit 0
