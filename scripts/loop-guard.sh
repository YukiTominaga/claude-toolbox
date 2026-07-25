#!/bin/bash
# loop-guard.sh — 外側ループの実行ゲート。1 イテレーションを始めてよいか判定する。
# 使い方: loop-guard.sh [--check]
#   標準出力: {"ok",...} の JSON 1 行
#   exit 0 = 実行してよい / exit 1 = 実行してはいけない(paused)
#
# 判定を通過したとき、このスクリプト自身が台帳に {"event":"start"} を記録する。
# 記録をエージェントの自己申告(loop-log.sh の呼び忘れ)に依存させないため:
# イテレーションが途中で失敗・中断しても、開始した事実は必ず残る。
# --check を付けると記録せず判定だけ返す(状態を見るだけで回数を増やさない)。
#
# **実行回数では止めない**(撤廃済み。docs/spec/budget-removal.md)。回数は数え続けるが
# 判定材料にはしない — 対話セッションでは人が見ており、回数で切ると邪魔になるだけで
# 暴走は防げない。同じ理由で経過時間でも金額でも止めない。
# 止めるのは status: paused だけ。これは人が倒す手動スイッチであって予算ではない。
# 無人実行の歯止めは scripts/loop-run.sh が定数として持つターン数上限が担う。
#
# 台帳に event を持たない旧形式の行は集計対象外になる。台帳は .gitignore 対象の
# ローカル履歴なので、移行時に当日分が 0 から数え直しになっても実害はない。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

LOOP="LOOP.md"
LEDGER_DIR=".claude/loop"
LEDGER="$LEDGER_DIR/run-log.jsonl"

check_only=0
[ "${1:-}" = "--check" ] && check_only=1

command -v jq >/dev/null 2>&1 || {
  echo '{"ok":true,"reason":"jq なし。判定をスキップ"}'
  exit 0
}

[ -f "$LOOP" ] || {
  echo '{"ok":true,"reason":"LOOP.md なし。判定をスキップ"}'
  exit 0
}

# frontmatter の値を取得(行末コメントと前後空白を除去)
get_field() {
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" {
      sub("^"k": *", ""); sub(" *#.*$", ""); gsub(/^ +| +$/, ""); print; exit
    }' "$LOOP"
}

status=$(get_field status)

if [ -n "$status" ] && [ "$status" != "active" ]; then
  jq -nc --arg s "$status" '{ok:false, reason:("LOOP.md が status: " + $s)}'
  exit 1
fi

# 当日の実行回数は**数えるだけ**。判定には使わない(/crystal:loop status が読む)
today=$(date +%Y-%m-%d)
runs_today=0
if [ -f "$LEDGER" ]; then
  runs_today=$(grep -c "\"ts\":\"$today.*\"event\":\"start\"" "$LEDGER" 2>/dev/null) || runs_today=0
fi
case "$runs_today" in '' | *[!0-9]*) runs_today=0 ;; esac

if [ "$check_only" -eq 0 ]; then
  if mkdir -p "$LEDGER_DIR" 2>/dev/null; then
    jq -nc --arg ts "$(date -Iseconds)" '{ts: $ts, event: "start"}' >>"$LEDGER" 2>/dev/null
    runs_today=$((runs_today + 1))
  fi
fi

jq -nc --argjson r "$runs_today" --argjson c "$check_only" \
  '{ok:true, runs_today:$r, recorded:($c==0)}'
exit 0
