#!/bin/bash
# signal-add.sh — 発見(摩擦・取りこぼし・未処理の気づき)を 1 件記録する。採番はこのスクリプトが行う。
# 使い方: signal-add.sh <タイトル> [source] [本文...]
#   標準出力: 採番した ID (例: S-3)
#   exit 0 = 作成した / exit 1 = 引数不正 / exit 3 = docs/signals/ がない
#
# エージェントに markdown を直書きさせないためのラッパー(loop-add.sh / loop-log.sh と同じ思想)。
# 本文は必ず引数で渡す。**標準入力からは読まない**: 無人ループやフックから呼ばれたとき、
# 端末が繋がっていない状態で cat を待って永久にハングするため。
#
# backlog との違い: backlog は「やること」、signal は「気づいたこと」。
# signal はそれ単体では着手できない(誰かが backlog に昇格させて初めて仕事になる)。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "usage: signal-add.sh <タイトル> [source] [本文...]" >&2
  exit 1
fi

title=$(printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
source_ref="${2:-}"
shift 2 2>/dev/null || shift $#
body="$*"

[ -n "$title" ] || {
  echo "signal-add: タイトルが空です" >&2
  exit 1
}

DIR="docs/signals"
[ -d "$DIR" ] || {
  echo "signal-add: $DIR がありません (/crystal:loop init で作成できます)" >&2
  exit 3
}

max=$(find "$DIR" -maxdepth 1 -name 'S-*.md' 2>/dev/null |
  sed -E 's|.*/S-([0-9]+)\.md$|\1|' | grep -E '^[0-9]+$' | sort -n | tail -n1)
case "$max" in '' | *[!0-9]*) max=0 ;; esac
id="S-$((max + 1))"

# ファイル名は連番だけにする。タイトルは日本語が主なので、ASCII の slug を付けると
# 断片(「eval の判定履歴が...」→ S-1-eval)になって内容を誤解させる。
# 一覧は `grep -H '^# ' docs/signals/*.md` で見る。
file="$DIR/$id.md"

[ -n "$body" ] || body="(本文なし)"

{
  printf -- '---\n'
  printf 'id: %s\n' "$id"
  printf 'created: %s\n' "$(date +%Y-%m-%d)"
  printf 'source: %s\n' "$source_ref"
  printf 'status: open\n'
  printf -- '---\n'
  printf '# %s\n\n' "$title"
  printf '%s\n' "$body"
} >"$file" || exit 1

echo "$id"
printf 'signal-add: %s (%s)\n' "$id" "$file" >&2
