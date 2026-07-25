#!/bin/bash
# loop-add.sh — キューに項目を1件追記する。採番はこのスクリプトが行う。
# 使い方: loop-add.sh <タイトル> [spec パス] [priority]
#   標準出力: 採番した ID (例: Q-8)
#   exit 0 = 追記した / exit 1 = 引数不正 / exit 3 = キューファイルがない
# エージェントに markdown を直書きさせないためのラッパー(loop-log.sh と同じ思想)。
# 連番は既存の Q-<n> の最大値+1。GH-<n> は Issue 番号なので採番対象から除外する。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "usage: loop-add.sh <タイトル> [spec パス] [priority]" >&2
  exit 1
fi

# タイトルは1行に畳む。行末コメントの開始記号は書式を壊すので除去する
title=$(printf '%s' "$1" | tr '\n' ' ' | sed -E 's/<!--|-->//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
spec="${2:-}"
priority="${3:-}"

[ -n "$title" ] || {
  echo "loop-add: タイトルが空です" >&2
  exit 1
}

case "$priority" in
'' | high | med | low) ;;
*)
  echo "loop-add: priority は high|med|low のいずれか (指定: $priority)" >&2
  exit 1
  ;;
esac

QUEUE="docs/backlog.md"
[ -f "$QUEUE" ] || {
  echo "loop-add: $QUEUE がありません (/crystal:loop init で作成できます)" >&2
  exit 3
}

max=$(grep -oE '^[[:space:]]*- \[[ xX]\] Q-[0-9]+' "$QUEUE" 2>/dev/null |
  grep -oE '[0-9]+$' | sort -n | tail -n1)
case "$max" in '' | *[!0-9]*) max=0 ;; esac
id="Q-$((max + 1))"

meta=""
[ -n "$spec" ] && meta="spec: $spec"
if [ -n "$priority" ]; then
  [ -n "$meta" ] && meta="$meta, "
  meta="${meta}priority: $priority"
fi

line="- [ ] $id: $title"
[ -n "$meta" ] && line="$line  <!-- $meta -->"

# 末尾に改行が無いファイルへの追記で行が繋がるのを防ぐ
if [ -s "$QUEUE" ] && [ "$(tail -c1 "$QUEUE" | wc -l)" -eq 0 ]; then
  printf '\n' >>"$QUEUE"
fi

printf '%s\n' "$line" >>"$QUEUE" || exit 1

echo "$id"
printf 'loop-add: %s\n' "$line" >&2
