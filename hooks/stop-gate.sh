#!/bin/bash
# stop-gate.sh — 完了宣言時の検証ゲート
# Claude が応答を終えようとしたとき、リポジトリに変更があれば
# テスト・型チェック・lint を実行し、失敗していれば exit 2 で差し戻す。
set -u

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

FAILED=""
run_check() {
  local name="$1"; shift
  local out
  if ! out=$("$@" 2>&1); then
    FAILED="${FAILED}\n--- ${name} 失敗 ---\n$(printf '%s' "$out" | tail -n 40)"
  fi
}

# --- Node / TypeScript プロジェクト ---
if [ -f package.json ]; then
  jq -e '.scripts.typecheck' package.json >/dev/null 2>&1 && run_check "typecheck" npm run -s typecheck
  jq -e '.scripts.lint'      package.json >/dev/null 2>&1 && run_check "lint"      npm run -s lint
  jq -e '.scripts.test'      package.json >/dev/null 2>&1 && run_check "test"      npm test -- --silent
fi

# --- Python プロジェクト ---
if [ -f pyproject.toml ] || [ -f setup.py ]; then
  command -v ruff >/dev/null 2>&1 && run_check "ruff" ruff check .
  if command -v pytest >/dev/null 2>&1 && { [ -d tests ] || [ -d test ]; }; then
    run_check "pytest" pytest -q
  fi
fi

if [ -n "$FAILED" ]; then
  printf '検証ゲート失敗。以下のエラーを修正するまで完了と報告しないこと。修正後は実際のコマンド出力を根拠として提示すること。%b\n' "$FAILED" >&2
  exit 2
fi

exit 0
