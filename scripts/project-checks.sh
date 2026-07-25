#!/bin/bash
# project-checks.sh — プロジェクトの L1 検証(型・lint・テスト)をまとめて実行する。
# 使い方: project-checks.sh
#   exit 0 = 緑、または実行できるチェックが無い
#   exit 1 = 赤。失敗したチェック名と出力の末尾を stdout に出す
#
# 呼び出し元は 2 つ:
#   hooks/stop-gate.sh  ゴールが無いセッションの完了ゲート
#   hooks/goal-gate.sh  内側ループの毎ラウンドのゲート(judge より手前 = 安い順)
#
# **git の状態を見ないこと**。「変更が無ければスキップ」は stop-gate 側のポリシーであり、
# ここに持ち込むと内側ループで L1 が消える: auto-commit と「feature ブランチでは自由に
# コミット」の運用により、Stop 時点の作業ツリーは空が普通になるため。
# evals/cases/checks-ignores-git.md がこの退行を検出する。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

FAILED=""
run_check() {
  local name="$1"
  shift
  local out
  if ! out=$("$@" 2>&1); then
    FAILED="${FAILED}\n--- ${name} 失敗 ---\n$(printf '%s' "$out" | tail -n 40)"
  fi
}

# --- Node / TypeScript プロジェクト ---
if [ -f package.json ] && command -v jq >/dev/null 2>&1; then
  jq -e '.scripts.typecheck' package.json >/dev/null 2>&1 && run_check "typecheck" npm run -s typecheck
  jq -e '.scripts.lint' package.json >/dev/null 2>&1 && run_check "lint" npm run -s lint
  jq -e '.scripts.test' package.json >/dev/null 2>&1 && run_check "test" npm test -- --silent
fi

# --- Python プロジェクト ---
if [ -f pyproject.toml ] || [ -f setup.py ]; then
  command -v ruff >/dev/null 2>&1 && run_check "ruff" ruff check .
  if command -v pytest >/dev/null 2>&1 && { [ -d tests ] || [ -d test ]; }; then
    run_check "pytest" pytest -q
  fi
fi

# --- プロジェクト固有のチェック ---
# npm / pytest の枠に収まらないプロジェクト(このリポジトリ自身など)のための逃げ道。
if [ -x .claude/checks.sh ]; then
  run_check "checks.sh" ./.claude/checks.sh
fi

if [ -n "$FAILED" ]; then
  printf '%b\n' "$FAILED"
  exit 1
fi

exit 0
