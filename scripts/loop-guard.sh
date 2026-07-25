#!/bin/bash
# loop-guard.sh — 外側ループの予算ゲート。1 イテレーションを始めてよいか判定する。
# 使い方: loop-guard.sh [--check]
#   標準出力: {"ok",...} の JSON 1 行
#   exit 0 = 実行してよい / exit 1 = 実行してはいけない(予算超過 or paused)
#
# 判定を通過したとき、このスクリプト自身が台帳に {"event":"start"} を記録する。
# 予算の消費をエージェントの自己申告(loop-log.sh の呼び忘れ)に依存させないため:
# イテレーションが途中で失敗・中断しても、開始した事実は必ず残る。
# --check を付けると記録せず判定だけ返す(状態を見るだけで予算を消費しない)。
#
# LOOP.md が無い場合は素通しする(fail-open)。予算はトークンではなく
# 「1日の実行回数」と「1実行の壁時計時間」で表現する(シェルから観測できる量に限る)。
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
max_cost=$(get_field max_cost_usd_per_day)
case "$max_runs" in '' | *[!0-9]*) max_runs=8 ;; esac
case "$max_minutes" in '' | *[!0-9]*) max_minutes=30 ;; esac
# 実費の上限は任意。未設定なら回数と時間による近似だけで判定する
# (対話セッションではコストを観測できないため、そこでは常に未設定になる)
case "$max_cost" in *[!0-9.]* | '') max_cost="" ;; esac

if [ -n "$status" ] && [ "$status" != "active" ]; then
  jq -nc --arg s "$status" '{ok:false, reason:("LOOP.md が status: " + $s)}'
  exit 1
fi

today=$(date +%Y-%m-%d)
runs_today=0
if [ -f "$LEDGER" ]; then
  runs_today=$(grep -c "\"ts\":\"$today.*\"event\":\"start\"" "$LEDGER" 2>/dev/null) || runs_today=0
fi
case "$runs_today" in '' | *[!0-9]*) runs_today=0 ;; esac

if [ "$runs_today" -ge "$max_runs" ]; then
  jq -nc --argjson r "$runs_today" --argjson m "$max_runs" \
    '{ok:false, runs_today:$r, max_runs_per_day:$m,
      reason:"本日の実行回数が上限に達しました"}'
  exit 1
fi

# --- 実費の上限 (無人実行のみ観測できる) ---
# 台帳の cost 行は loop-run.sh が実行のたびに積む。失敗した実行のコストも含める:
# 含めないと、失敗を繰り返すループが無限に課金できてしまう。
cost_today=0
cost_remaining=""
if [ -n "$max_cost" ]; then
  if [ -f "$LEDGER" ]; then
    cost_today=$(grep "\"ts\":\"$today.*\"event\":\"cost\"" "$LEDGER" 2>/dev/null |
      jq -s 'map(.cost_usd // 0) | add // 0' 2>/dev/null) || cost_today=0
  fi
  case "$cost_today" in '' | null) cost_today=0 ;; esac
  # 小数の比較はシェルでできないので awk に任せる
  if awk -v a="$cost_today" -v b="$max_cost" 'BEGIN { exit !(a >= b) }'; then
    jq -nc --argjson c "$cost_today" --argjson m "$max_cost" \
      '{ok:false, cost_today_usd:$c, max_cost_usd_per_day:$m,
        reason:"本日の実費が上限に達しました"}'
    exit 1
  fi
  cost_remaining=$(awk -v a="$cost_today" -v b="$max_cost" 'BEGIN { printf "%.4f", b - a }')
fi

if [ "$check_only" -eq 0 ]; then
  if mkdir -p "$LEDGER_DIR" 2>/dev/null; then
    jq -nc --arg ts "$(date -Iseconds)" '{ts: $ts, event: "start"}' >>"$LEDGER" 2>/dev/null
    runs_today=$((runs_today + 1))
  fi
fi

jq -nc --argjson r "$runs_today" --argjson m "$max_runs" --argjson t "$max_minutes" \
  --argjson c "$check_only" --argjson ct "$cost_today" --arg rem "$cost_remaining" \
  '{ok:true, runs_today:$r, max_runs_per_day:$m, max_minutes_per_run:$t, recorded:($c==0),
    cost_today_usd:$ct}
   + (if $rem == "" then {} else {cost_remaining_usd:($rem|tonumber)} end)'
exit 0
