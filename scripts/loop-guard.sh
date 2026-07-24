#!/bin/bash
# loop-guard.sh — 外側ループの予算ゲート。1 イテレーションを始めてよいか判定する。
# 使い方: loop-guard.sh
#   標準出力: {"ok",...} の JSON 1 行
#   exit 0 = 実行してよい / exit 1 = 実行してはいけない(予算超過 or paused)
# LOOP.md が無い場合は素通しする(fail-open)。予算はトークンではなく
# 「1日の実行回数」と「1実行の壁時計時間」で表現する(シェルから観測できる量に限る)。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

LOOP="LOOP.md"
LEDGER=".claude/loop/run-log.jsonl"

command -v jq >/dev/null 2>&1 || {
  echo '{"ok":true,"reason":"jq なし。予算判定をスキップ"}'
  exit 0
}

[ -f "$LOOP" ] || {
  echo '{"ok":true,"reason":"LOOP.md なし。予算判定をスキップ"}'
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
max_runs=$(get_field max_runs_per_day)
max_minutes=$(get_field max_minutes_per_run)
case "$max_runs" in '' | *[!0-9]*) max_runs=8 ;; esac
case "$max_minutes" in '' | *[!0-9]*) max_minutes=30 ;; esac

if [ -n "$status" ] && [ "$status" != "active" ]; then
  jq -nc --arg s "$status" '{ok:false, reason:("LOOP.md が status: " + $s)}'
  exit 1
fi

today=$(date +%Y-%m-%d)
runs_today=0
if [ -f "$LEDGER" ]; then
  runs_today=$(grep -c "\"ts\":\"$today" "$LEDGER" 2>/dev/null) || runs_today=0
fi
case "$runs_today" in '' | *[!0-9]*) runs_today=0 ;; esac

if [ "$runs_today" -ge "$max_runs" ]; then
  jq -nc --argjson r "$runs_today" --argjson m "$max_runs" \
    '{ok:false, runs_today:$r, max_runs_per_day:$m,
      reason:"本日の実行回数が上限に達しました"}'
  exit 1
fi

jq -nc --argjson r "$runs_today" --argjson m "$max_runs" --argjson t "$max_minutes" \
  '{ok:true, runs_today:$r, max_runs_per_day:$m, max_minutes_per_run:$t}'
exit 0
