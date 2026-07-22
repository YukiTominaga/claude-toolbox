#!/bin/bash
# lint-changed.sh — Edit/Write 直後に編集対象ファイルのみを lint する。
# 編集のたびに走るため軽量に保つ。フルビルド・テストは stop-gate.sh 側。
set -u

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

case "$file" in
  *.ts|*.tsx|*.js|*.jsx)
    if [ -f package.json ] && npx --no-install eslint --version >/dev/null 2>&1; then
      if ! out=$(npx --no-install eslint --no-warn-ignored "$file" 2>&1); then
        printf 'lint違反あり。以下を修正すること:\n%s\n' "$out" >&2
        exit 2
      fi
    fi
    ;;
  *.py)
    if command -v ruff >/dev/null 2>&1; then
      if ! out=$(ruff check "$file" 2>&1); then
        printf 'ruff違反あり。以下を修正すること:\n%s\n' "$out" >&2
        exit 2
      fi
    fi
    ;;
esac

exit 0
