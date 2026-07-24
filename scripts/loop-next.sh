#!/bin/bash
# loop-next.sh — 外側ループの discover。リポジトリ内キューから次の 1 件を取り出す。
# 使い方: loop-next.sh [キューファイル]   (既定: docs/backlog.md)
#   標準出力: {"id","title","spec","priority","line","file"} の JSON 1 行
#   exit 0 = 取り出せた / exit 3 = キューが枯れた(ループを止めてよい合図)
# 判定を決定的にするため、常に「先頭の未着手項目」を返す。並べ替えは人間の仕事。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 3

QUEUE="${1:-docs/backlog.md}"

command -v jq >/dev/null 2>&1 || {
  echo "loop-next: jq が見つかりません" >&2
  exit 3
}

[ -f "$QUEUE" ] || {
  echo "loop-next: $QUEUE がありません (/crystal:loop init で作成できます)" >&2
  exit 3
}

# 未着手 (- [ ]) の先頭行。HTML コメント内の例示行を拾わないよう行頭一致で探す
hit=$(grep -n -m1 -E '^[[:space:]]*- \[ \] ' "$QUEUE") || {
  echo "loop-next: $QUEUE に未着手の項目がありません" >&2
  exit 3
}

lineno=${hit%%:*}
raw=${hit#*:}

# 行末の <!-- key: value, ... --> をメタデータとして分離
meta=$(printf '%s' "$raw" | sed -nE 's/.*<!--[[:space:]]*(.*[^[:space:]])[[:space:]]*-->.*/\1/p')
body=$(printf '%s' "$raw" |
  sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//; s/<!--.*-->//; s/[[:space:]]+$//')

# 先頭が "<ID>: " ならそれを id として切り出す
id=$(printf '%s' "$body" | sed -nE 's/^([A-Za-z0-9_.-]+):[[:space:]].*/\1/p')
title=$body
[ -n "$id" ] && title=$(printf '%s' "$body" | sed -E 's/^[A-Za-z0-9_.-]+:[[:space:]]*//')

meta_get() { # $1=key
  printf '%s' "$meta" | tr ',' '\n' |
    sed -nE "s/^[[:space:]]*$1:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p" | head -n1
}

jq -nc \
  --arg id "$id" \
  --arg title "$title" \
  --arg spec "$(meta_get spec)" \
  --arg priority "$(meta_get priority)" \
  --arg file "$QUEUE" \
  --argjson line "$lineno" \
  '{id: $id, title: $title, spec: $spec, priority: $priority, file: $file, line: $line}'
