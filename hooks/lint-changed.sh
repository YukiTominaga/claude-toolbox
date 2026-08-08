#!/bin/bash
# lint-changed.sh — Edit/Write 直後に編集対象ファイルのみを lint する。
# 編集のたびに走るため軽量に保つ。フルビルド・テストは stop-gate.sh 側。
set -u

input=$(cat)
file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# eslint の設定がプロジェクトに存在するか。
# eslint 本体は親ディレクトリや global から解決できてしまうため、
# 「実行できること」を条件にすると、eslint を使っていないプロジェクトでも起動し、
# "couldn't find an eslint.config.js" という設定エラーを lint 違反として報告してしまう
# (編集のたびに偽の差し戻しが出る)。設定の有無で判定する。
has_eslint_config() {
  for f in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts \
    eslint.config.mts eslint.config.cts .eslintrc .eslintrc.js .eslintrc.cjs \
    .eslintrc.json .eslintrc.yml .eslintrc.yaml; do
    [ -f "$f" ] && return 0
  done
  jq -e '.eslintConfig' package.json >/dev/null 2>&1 && return 0
  return 1
}

case "$file" in
  *.ts|*.tsx|*.js|*.jsx)
    if [ -f package.json ] && has_eslint_config &&
      npx --no-install eslint --version >/dev/null 2>&1; then
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
