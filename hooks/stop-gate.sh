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
checked_file=""
if [ -n "$session_id" ]; then
  own_marker="$(crystal_state_dir)/${session_id}.stop-gate.blocked"
  checked_file="$(crystal_state_dir)/${session_id}.stop-gate.checked"
fi

record_checked() { # 現在のツリー状態を「検査済み」として記録する
  [ -n "$checked_file" ] || return 0
  mkdir -p "$(dirname "$checked_file")" 2>/dev/null &&
    tree_digest >"$checked_file" 2>/dev/null
}

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
    # 脱出口で通した状態も検査済みとして記録する。ベースライン方式では差分が
    # セッション中ずっと残るため、記録が無いと同じ失敗で毎ターン差し戻し続ける
    record_checked
    exit 0
  fi
fi

# --- 変更がなければゲート不要(質問応答セッション等) ---
# 比較の基点はセッション開始時点の HEAD (record-baseline.sh が記録)。
# HEAD 比較のままだと、応答を終える前に commit するだけで「変更なし」になり、
# テストを一度も実行しないまま完了できる
changed=$(changed_files "$(session_baseline "$session_id")")
[ -n "$changed" ] || exit 0

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

# --- 前回検査した状態と同一なら再検査しない ---
# ベースライン方式では検証済みの変更がセッション中ずっと差分として残る。
# 状態のダイジェストで判定しないと、検証後の会話だけのターンでも毎回フルテストが
# 走り、待ち時間だけが積み上がってゲートごと無視される
if [ -n "$checked_file" ] && [ -f "$checked_file" ] &&
  [ "$(tree_digest)" = "$(cat "$checked_file" 2>/dev/null)" ]; then
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
  # 自分が差し戻したことを記録する (再停止で自分の分だけを素通しするため)
  if [ -n "$own_marker" ]; then
    mkdir -p "$(dirname "$own_marker")" 2>/dev/null && touch "$own_marker" 2>/dev/null
  fi
  printf '検証ゲート失敗。以下のエラーを修正するまで完了と報告しないこと。修正後は実際のコマンド出力を根拠として提示すること。%b\n' "$FAILED" >&2
  exit 2
fi

# 検査が通った状態を記録する (同一状態のままの停止では再検査しない)。
# 検査自身が生成物 (キャッシュ等) を作ることがあるため、実行後の状態を記録する
record_checked
exit 0
