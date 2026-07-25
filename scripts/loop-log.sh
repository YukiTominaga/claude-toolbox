#!/bin/bash
# loop-log.sh — 外側ループの実行台帳に「結果」の 1 行を追記する / 直近の結果を読み出す。
# 使い方: loop-log.sh <item_id> <done|failed|blocked|skipped> [rounds] [メモ...]
#         loop-log.sh --recent [N]   直近 N 件(既定 5)の結果行を新しい順に出す
# 追記先: $CLAUDE_PROJECT_DIR/.claude/loop/run-log.jsonl
# ループがクラッシュしてもコンテキストが飛んでも「何を回したか」が残るようにする。
# エージェントに JSON を直書きさせず、必ずこのスクリプトを経由すること。
#
# --recent は台帳を「書かれるだけ」で終わらせないための読み口。イテレーションの冒頭で
# これを読むことで、前回どこで詰まったかを踏まえてから着手できる(同じ壁に二度当たらない)。
#
# 台帳には event 付きの 2 種類の行が入る:
#   {"event":"start"}   loop-guard.sh が実行開始時に記録する(予算の集計対象)
#   {"event":"<結果>"}  このスクリプトが記録する(何がどうなったかの履歴)
# 予算を数えるのは start 行だけなので、この呼び出しを忘れても予算判定は狂わない。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1

LEDGER_DIR=".claude/loop"
LEDGER="$LEDGER_DIR/run-log.jsonl"

# --- 読み出しモード ---
if [ "${1:-}" = "--recent" ]; then
  n="${2:-5}"
  case "$n" in '' | *[!0-9]*) n=5 ;; esac
  [ -f "$LEDGER" ] || exit 0
  # start 行は予算の集計用なので出さない。結果行だけを新しい順に返す。
  # 逆順は awk で行う (tail -r は BSD 専用、tac は GNU 専用で環境を選ぶ)
  grep -v '"event":"start"' "$LEDGER" 2>/dev/null | tail -n "$n" |
    awk '{a[NR]=$0} END {for (i = NR; i > 0; i--) print a[i]}'
  exit 0
fi

if [ $# -lt 2 ]; then
  echo "usage: loop-log.sh <item_id> <done|failed|blocked|skipped> [rounds] [メモ...]" >&2
  echo "       loop-log.sh --recent [N]" >&2
  exit 1
fi

item_id="$1"
result="$2"
shift 2

case "$result" in
done | failed | blocked | skipped) ;;
*)
  echo "loop-log: result は done|failed|blocked|skipped のいずれか (指定: $result)" >&2
  exit 1
  ;;
esac

rounds=0
if [ $# -gt 0 ]; then
  case "$1" in
  '' | *[!0-9]*) ;;
  *)
    rounds="$1"
    shift
    ;;
  esac
fi
notes="$*"

command -v jq >/dev/null 2>&1 || {
  echo "loop-log: jq が見つかりません" >&2
  exit 1
}

mkdir -p "$LEDGER_DIR" || exit 1

jq -nc \
  --arg ts "$(date -Iseconds)" \
  --arg item_id "$item_id" \
  --arg result "$result" \
  --arg notes "$notes" \
  --argjson rounds "$rounds" \
  '{ts: $ts, event: $result, item_id: $item_id, result: $result, rounds: $rounds, notes: $notes}' \
  >>"$LEDGER" || exit 1

echo "loop-log: $item_id → $result (台帳: $LEDGER)"
