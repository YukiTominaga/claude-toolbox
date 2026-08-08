#!/bin/bash
# adr-lint.sh — docs/adr/*.md の構造を機械検証する。
#
# /crystal:adr の指示のうち機械で判定できる部分をここに移す。
# 「却下理由が事実か」は判定できないが、「却下案が 1 つも無い ADR」は検出できる。
# 番号衝突 (並行ブランチ・worktree で同じ番号が生まれる) と superseded の
# 片側だけ更新された状態は、散文の手順では防げないためここが唯一の検出口になる。
#
# 使い方: adr-lint.sh [ADR ディレクトリ]   (既定: docs/adr)
# 終了コード: 0 = 指摘なし (対象が無い場合を含む) / 1 = 指摘あり
set -u

DIR="${1:-docs/adr}"

findings=0
report() {
  printf '%s: %s\n' "$1" "$2"
  findings=$((findings + 1))
}

if [ ! -d "$DIR" ]; then
  printf 'ADR lint: %s が無いため検査対象なし\n' "$DIR"
  exit 0
fi

files=$(find "$DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
if [ -z "$files" ]; then
  printf 'ADR lint: %s に ADR が無いため検査対象なし\n' "$DIR"
  exit 0
fi

count=0
nums=""

while IFS= read -r f; do
  [ -n "$f" ] || continue
  base=$(basename "$f")
  count=$((count + 1))

  # --- ファイル名 NNNN-slug.md ---
  # 形式が違うと採番も逆リンクも辿れないため、以降の検査は行わない
  if ! printf '%s' "$base" | grep -qE '^[0-9]{4}-[a-z0-9]+(-[a-z0-9]+)*\.md$'; then
    report "$base" "ファイル名が NNNN-slug.md 形式でない (slug は英小文字 kebab-case)"
    continue
  fi
  num=${base%%-*}

  # --- 番号の重複 (並行ブランチでの採番衝突) ---
  case " $nums " in
  *" $num "*) report "$base" "ADR 番号 $num が重複している" ;;
  esac
  nums="$nums $num"

  # --- 見出しの番号がファイル名と一致するか ---
  head_num=$(grep -m1 -E '^# ADR-[0-9]{4}:' "$f" | sed -E 's/^# ADR-([0-9]{4}):.*/\1/')
  if [ -z "$head_num" ]; then
    report "$base" "見出しが '# ADR-NNNN: <タイトル>' の形式でない"
  elif [ "$head_num" != "$num" ]; then
    report "$base" "見出しの番号 ($head_num) がファイル名 ($num) と一致しない"
  fi

  # --- 日付 ---
  date_line=$(grep -m1 -E '^- 日付:' "$f")
  if [ -z "$date_line" ]; then
    report "$base" "'- 日付:' 行が無い"
  elif ! printf '%s' "$date_line" | grep -qE '^- 日付: [0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    report "$base" "日付が YYYY-MM-DD 形式でない"
  fi

  # --- ステータス ---
  status_line=$(grep -m1 -E '^- ステータス:' "$f")
  status=""
  if [ -z "$status_line" ]; then
    report "$base" "'- ステータス:' 行が無い"
  else
    status=$(printf '%s' "$status_line" | sed -E 's/^- ステータス:[[:space:]]*//')
    case "$status" in
    proposed | accepted | deprecated) ;;
    "superseded by ADR-"[0-9][0-9][0-9][0-9]) ;;
    *) report "$base" "ステータスの値が不正: '$status' (proposed / accepted / deprecated / superseded by ADR-NNNN)" ;;
    esac
  fi

  # --- 必須セクション ---
  for sec in コンテキスト 決定 検討した選択肢 影響; do
    grep -qE "^## ${sec}\$" "$f" || report "$base" "必須セクション '## ${sec}' が無い"
  done

  # --- 却下案 ---
  # 却下案の無い ADR は「なぜ他を採らなかったか」を残せておらず、ADR の主価値を欠く
  grep -qE '^### .*却下' "$f" ||
    report "$base" "却下した案が無い ('### 案 X: <名前>(却下)' が 1 つ以上要る)"

  # --- テンプレートのプレースホルダ残留 ---
  if grep -qE 'NNNN|YYYY-MM-DD' "$f"; then
    report "$base" "テンプレートのプレースホルダ (NNNN / YYYY-MM-DD) が残っている"
  fi

  # --- superseded の参照先と逆リンク ---
  case "$status" in
  "superseded by ADR-"*)
    target=${status#superseded by ADR-}
    tfile=$(find "$DIR" -maxdepth 1 -type f -name "${target}-*.md" 2>/dev/null | head -1)
    if [ -z "$tfile" ]; then
      report "$base" "superseded by ADR-$target の参照先が存在しない"
    elif ! grep -q "ADR-$num" "$tfile"; then
      report "$base" "ADR-$target 側に ADR-$num への逆リンクが無い (関連: に 'ADR-$num を置き換える' を書く)"
    fi
    ;;
  esac
done <<EOF
$files
EOF

if [ "$findings" -eq 0 ]; then
  printf 'ADR lint: 指摘なし (%s 件検査)\n' "$count"
  exit 0
fi

printf 'ADR lint: %s 件の指摘 (%s 件検査)\n' "$findings" "$count"
exit 1
