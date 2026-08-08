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

# --- git 管理下でなければ対象外 ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# 分類・状態の定義は他のゲートと共有する (hooks/lib/classify.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
own_marker=""
[ -n "$session_id" ] && own_marker="$(crystal_state_dir)/${session_id}.stop-gate.blocked"

# --- 再帰防止: このフック自身による差し戻し後の再停止では素通しする ---
# stop_hook_active は「どれかの Stop hook が差し戻した」フラグで、自分のものとは限らない。
# フラグだけで素通しすると、change-gate の差し戻し後に追加された(壊れているかもしれない)
# テストを一度も実行しないまま応答を終えられる。自分の差し戻しの記録があるときだけ
# 素通しする (直せない失敗で詰まないための脱出口は残る)。
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  # session_id が取れないビルドでは従来どおりチェーン全体で素通しする (ループ防止を優先)
  [ -n "$own_marker" ] || exit 0
  if [ -f "$own_marker" ]; then
    rm -f "$own_marker" 2>/dev/null
    exit 0
  fi
fi

# --- 変更がなければゲート不要(質問応答セッション等) ---
if git diff --quiet HEAD 2>/dev/null \
  && git diff --cached --quiet 2>/dev/null \
  && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  exit 0
fi

# --- このセッションに作業痕跡が無ければゲート不要 ---
# ツリーが汚れていても、それがセッション開始前からの汚れ (人間の書きかけ等) なら
# このターンで検証する意味は無い。純粋な質問応答のたびにフルテストを回すと、
# 待ち時間だけが積み上がってゲートごと無視される。transcript が取れないビルドでは
# 従来どおり常に検証する (ゲートを黙って殺さない)。
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$tp" ] && [ -f "$tp" ]; then
  marks=$(session_work_marks "$tp")
  did_work=0
  printf '%s\n' "$marks" | grep -q '^FILE' && did_work=1
  [ "$did_work" = "0" ] && printf '%s\n' "$marks" | grep -q '^BASH$' && did_work=1
  if [ "$did_work" = "0" ] && printf '%s\n' "$marks" | grep -q '^AGENT$'; then
    # サブエージェント起動は、コードを変更した記録があるときだけ作業とみなす。
    # 記録が引けないビルドでは安全側 (作業あり) に倒す
    if [ -z "$session_id" ] || [ -s "$(subagent_edits_file "$session_id")" ]; then
      did_work=1
    fi
  fi
  [ "$did_work" = "1" ] || exit 0
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
  # 自分が差し戻したことを記録する (再停止で自分の分だけを素通しするため)
  if [ -n "$own_marker" ]; then
    mkdir -p "$(dirname "$own_marker")" 2>/dev/null && touch "$own_marker" 2>/dev/null
  fi
  printf '検証ゲート失敗。以下のエラーを修正するまで完了と報告しないこと。修正後は実際のコマンド出力を根拠として提示すること。%b\n' "$FAILED" >&2
  exit 2
fi

exit 0
