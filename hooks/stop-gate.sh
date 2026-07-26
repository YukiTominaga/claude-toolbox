#!/bin/bash
# stop-gate.sh — 完了宣言時の検証ゲート
# Claude が応答を終えようとしたとき、リポジトリに変更があれば
# テスト・型チェック・lint を実行し、失敗していれば exit 2 で差し戻す。
set -u

input=$(cat)

# --- プロジェクトルートへ移動 ---
# `cd .` は必ず成功するため `cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0` ではガードにならず、
# CLAUDE_PROJECT_DIR 未設定時にカレント(モノレポのサブパッケージ等)を検証してしまう。
# 未設定なら git のトップレベルにフォールバックする。
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0

# --- ゴールループ中か ---
# goal-gate は stop_hook_active を意図的に無視して毎ターン差し戻す。
# そのため下の素通しをそのまま適用すると、ゴールループに入った瞬間から
# テスト・型チェック・lint の実検証が二度と走らなくなる(Haiku の見た目判定だけになる)。
# ゴールが active の間は毎ターン検証する。
goal_active=0
if [ -f .claude/goal.md ] &&
  grep -qE '^status:[[:space:]]*active[[:space:]]*$' .claude/goal.md 2>/dev/null; then
  goal_active=1
fi

# --- 再帰防止: このフックによる差し戻し後の再停止では素通しする(ゴールループ中を除く) ---
if [ "$goal_active" = "0" ] &&
  [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

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
  # --silent は npm 自身のフラグとして渡す。`npm test -- --silent` にすると
  # test スクリプトの argv に --silent が注入され、引数を検査するランナーが誤って失敗する
  jq -e '.scripts.test'      package.json >/dev/null 2>&1 && run_check "test"      npm test --silent
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
