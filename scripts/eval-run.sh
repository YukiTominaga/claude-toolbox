#!/bin/bash
# eval-run.sh — evals/cases/*.md を実行する eval ランナー
# 使い方: eval-run.sh [ケースID...]   (省略時は全ケース)
#   command 型: run を実行し exit code / 出力の正規表現を検証
#   rubric 型:  対象テキストを claude -p (Haiku) のルーブリック判定にかける
# 1 件でも FAIL があれば exit 1。claude CLI 不在時、rubric 型は SKIP になる。
set -u

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1

CASES_DIR="evals/cases"
if [ ! -d "$CASES_DIR" ]; then
  echo "evals/cases/ が見つかりません (カレント: $(pwd))" >&2
  exit 1
fi

# frontmatter の値を取得(行末コメント・前後空白・囲みダブルクォートを除去)
get_field() { # $1=file $2=key
  awk -v k="$2" '
    /^---$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" {
      sub("^"k": *", ""); sub(" +# .*$", ""); gsub(/^ +| +$/, ""); gsub(/^"|"$/, ""); print; exit
    }' "$1"
}

# 「## <名前>」セクションの本文を取得
get_section() { # $1=file $2=section
  awk -v s="$2" '$0 == "## "s {f=1;next} /^## /{f=0} f' "$1"
}

files=()
if [ $# -gt 0 ]; then
  for id in "$@"; do
    f="$CASES_DIR/$id.md"
    if [ -f "$f" ]; then files+=("$f"); else echo "SKIP  $id — ケースファイルなし"; fi
  done
else
  for f in "$CASES_DIR"/*.md; do [ -f "$f" ] && files+=("$f"); done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "実行対象のケースがありません" >&2
  exit 1
fi

pass=0 fail=0 skip=0
rows=()

for f in "${files[@]}"; do
  id=$(get_field "$f" id)
  [ -n "$id" ] || id=$(basename "$f" .md)
  type=$(get_field "$f" type)
  run=$(get_field "$f" run)

  case "$type" in
  command)
    expect_exit=$(get_field "$f" expect_exit)
    case "$expect_exit" in '' | *[!0-9]*) expect_exit=0 ;; esac
    expect_output=$(get_field "$f" expect_output)
    out=$(bash -c "$run" 2>&1)
    ec=$?
    if [ "$ec" -ne "$expect_exit" ]; then
      rows+=("FAIL  $id — exit $ec (期待 $expect_exit)")
      fail=$((fail + 1))
    elif [ -n "$expect_output" ] && ! printf '%s' "$out" | grep -qE "$expect_output"; then
      rows+=("FAIL  $id — 出力が /$expect_output/ に一致しない")
      fail=$((fail + 1))
    else
      rows+=("PASS  $id")
      pass=$((pass + 1))
    fi
    ;;
  rubric)
    if ! command -v claude >/dev/null 2>&1; then
      rows+=("SKIP  $id — claude CLI なし (rubric 判定不可)")
      skip=$((skip + 1))
      continue
    fi
    if [ -n "$run" ]; then target=$(bash -c "$run" 2>&1); else target=$(get_section "$f" "対象"); fi
    rubric=$(get_section "$f" "ルーブリック")
    prompt="あなたは評価器です。以下のルーブリックに照らして対象を判定し、JSON のみを出力してください。説明文・コードフェンスは付けないこと:
{\"pass\": true|false, \"reason\": \"簡潔な理由\"}

## ルーブリック
${rubric}

## 対象
${target}"
    result=$(printf '%s' "$prompt" | CRYSTAL_GOAL_JUDGE=1 timeout 120 \
      claude -p --model claude-haiku-4-5-20251001 \
      --settings '{"disableAllHooks": true}' 2>/dev/null)
    json=$result
    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
      json=$(printf '%s' "$result" | sed -n '/{/,/}/p')
    fi
    verdict=$(printf '%s' "$json" | jq -r '.pass' 2>/dev/null)
    reason=$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null)
    if [ "$verdict" = "true" ]; then
      rows+=("PASS  $id")
      pass=$((pass + 1))
    elif [ "$verdict" = "false" ]; then
      rows+=("FAIL  $id — $reason")
      fail=$((fail + 1))
    else
      rows+=("SKIP  $id — rubric 判定の出力をパースできず")
      skip=$((skip + 1))
    fi
    ;;
  *)
    rows+=("SKIP  $id — 不明な type: ${type:-なし}")
    skip=$((skip + 1))
    ;;
  esac
done

echo "== eval 結果 =="
for r in "${rows[@]}"; do echo "$r"; done
echo "-- 合格 $pass / 不合格 $fail / スキップ $skip --"

[ "$fail" -eq 0 ] || exit 1
exit 0
