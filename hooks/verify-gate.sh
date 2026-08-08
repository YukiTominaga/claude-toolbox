#!/bin/bash
# verify-gate.sh — 独立検証を通さずに実装を終えることを止める Stop hook
#
# 実装を変更したまま、crystal:verifier による独立検証を 1 度も回さずに応答を
# 終えようとしたら exit 2 で差し戻す。
#
# 判定材料はメインセッションの transcript。そこには
#   - Write / Edit / MultiEdit / NotebookEdit の tool_use  = 「コードを変更した」印
#   - Agent (ビルドにより Task) の tool_use で subagent_type が verifier = 「検証を回した」印
# が時系列で並ぶ。最後に現れた印が VERIFY なら「最後の変更より後に検証した」ことになる。
#
# verifier は会話の経緯を引き継がない独立コンテキストで動き、仕様と実行結果だけで
# 判定する。同一セッション内ではあるが、実装した文脈から切り離す目的はこれで満たす。
set -u

if [ "${CRYSTAL_VERIFY_GATE:-on}" = "off" ]; then
  exit 0
fi

input=$(cat)

# stop_hook_active では素通ししない(意図的な設計差)。
# change-gate と違い、ここには「理由を述べれば省いてよい」余地がほとんど無い。
# verifier を呼べばその時点で印が VERIFY になり自然に通るため、ループにはならない
# (呼ばずに終えようとし続けた場合だけ、ランタイム側のブロック上限で打ち切られる)。

project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# 分類の定義は change-gate.sh と共有する
. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"

changed=$(changed_files)
[ -n "$changed" ] || exit 0
impl=$(impl_files "$changed")
[ -n "$impl" ] || exit 0

# --- 仕様が無ければ発火しない ---
# verifier は docs/spec/ の受け入れ条件を根拠に判定する。仕様が無い状態で呼んでも
# 「検証不能」しか返せず、差し戻しても状況が変わらない = 抜けられないループになる。
# (実装変更に対する仕様の存在自体は change-gate.sh が別に担保している)
# サブディレクトリも見る: SPEC_RE は docs/spec/ 配下の全 .md を仕様と認めるので、
# ここが直下しか見ないと、仕様を機能別ディレクトリに整理した途端このゲートだけが黙って死ぬ。
have_spec=0
for d in docs/spec docs/specs; do
  [ -d "$d" ] || continue
  if find "$d" -type f -name '*.md' 2>/dev/null | grep -q .; then
    have_spec=1
    break
  fi
done
[ "$have_spec" = "1" ] || exit 0

tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# --- サブエージェントによるコード変更の記録を引く ---
# メイン transcript にはサブエージェントの編集は現れない (Task の起動しか見えない)。
# record-subagent-edits.sh (SubagentStop) が残した記録があるときだけ、
# サブエージェント起動 (AGENT 印) を「コードが変わったかもしれない」として扱う。
# 記録が無ければ AGENT 印は無視する (調査エージェントを差し戻す誤検出を出さない)。
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
sub_state=""
sub_edits=0
if [ -n "$session_id" ]; then
  sub_state=$(subagent_edits_file "$session_id")
  [ -s "$sub_state" ] && sub_edits=1
fi

# --- 印の列を取る (定義は classify.sh の session_work_marks) ---
# 変更痕跡はコードファイルへの編集だけを数える。docs/spec/ のステータス更新や
# README の修正で「検証が無効になった」とみなすと、検証直後に必ず差し戻されて
# 抜けられなくなる。設定ファイルも同じ理由で数えない。
# VERIFY の印には tool_use の id が付く。対応する tool_result (= verifier の本文) を
# 引くために要る。パスの分類は awk で 1 パスで行う (per-line の grep はフォークが嵩む)。
marks=$(session_work_marks "$tp")
reduced=$(printf '%s\n' "$marks" | ROOT="$project_dir/" CODE="$CODE_RE" \
  CONFIG="$CONFIG_RE" SPEC="$SPEC_RE" awk -F '\t' '
  BEGIN {
    root = ENVIRON["ROOT"]; code = ENVIRON["CODE"]
    config = ENVIRON["CONFIG"]; spec = ENVIRON["SPEC"]
  }
  $1 == "FILE" {
    p = $2
    if (index(p, root) == 1) p = substr(p, length(root) + 1)
    if (p ~ spec) next
    if (p ~ config) next
    if (p ~ code) print "EDIT"
    next
  }
  $1 == "AGENT"  { print "AGENT"; next }
  $1 == "VERIFY" { print $0; next }
')

TAB=$(printf '\t')
last=""
verify_id=""
have_verify=0
while IFS= read -r line; do
  case "$line" in
  EDIT) last="EDIT" ;;
  AGENT) [ "$sub_edits" = "1" ] && last="AGENT" ;;
  VERIFY*)
    last="VERIFY"
    have_verify=1
    verify_id=""
    case "$line" in *"$TAB"*) verify_id=${line#*"$TAB"} ;; esac
    ;;
  esac
done <<EOF
$reduced
EOF

# 印が 1 つも無い = このセッションはコードを触っていない (作業ツリーが元から汚れている、
# Bash 経由で書き換えた等)。このゲートの対象は「このセッションで実装した人」なので素通しする。
[ -n "$last" ] || exit 0

stop_hook_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)

# --- verifier の判定行を読む ---
# verifier は本文の末尾に判定行を 1 行返す契約になっている (agents/verifier.md)。
# 自由記述の要約を読み解くのではなく、この 1 行だけを見る。
# 契約が守られているかは tests/verify-gate.test.ts が agents/verifier.md 側と突き合わせる
# (片方だけ書き換えると、ここが黙って無力化されるのを防ぐため)。
VERDICT_RE='^[[:space:]]*CRYSTAL-VERDICT:[[:space:]]*(PASS|FAIL)'
verdict_line=""
read_verdict() { # $1 = VERIFY の tool_use id。verdict_line を設定する
  local result
  result=$(jq -Rr --arg id "$1" '
    fromjson? // empty
    | select(.type=="user") | .message.content[]?
    | select(.type=="tool_result" and .tool_use_id==$id)
    | if (.content | type) == "array"
      then (.content[]? | select(.type=="text") | .text)
      else (.content // "") end' "$tp" 2>/dev/null)
  verdict_line=$(printf '%s\n' "$result" | grep -E "$VERDICT_RE" | tail -n 1)
}

# 合否は判定行の先頭トークンだけで決める。行全体への部分一致にすると、
# "FAIL AC-PASSWORD-VALIDATION" のように detail へ PASS を含むだけの不合格が合格扱いになる
verdict_token() { # $1 = 判定行 → PASS / FAIL
  printf '%s' "$1" | sed -E 's/^[[:space:]]*CRYSTAL-VERDICT:[[:space:]]*(PASS|FAIL).*$/\1/'
}

fail_block() { # $1 = 判定行
  local detail
  detail=$(printf '%s' "$1" | sed -E 's/^[[:space:]]*CRYSTAL-VERDICT:[[:space:]]*FAIL[[:space:]]*//')
  {
    printf '独立検証が不合格です。\n'
    printf 'crystal:verifier は docs/spec/ の受け入れ条件を満たしていないと判定しました。\n'
    [ -n "$detail" ] && printf '未達: %s\n' "$detail"
    printf '\nverifier の報告にある「満たさない」「未検証」の項目を解消してから、再度 verifier を通すこと。\n'
    printf '仕様の側が実態と合っていない場合は、docs/spec/ を直すのが正しい解決になることもあります。\n'
    printf '(このゲートを一時的に外す場合は CRYSTAL_VERIFY_GATE=off)\n'
  } >&2
  exit 2
}

# --- 最後の印がメインセッション自身の変更なら、そもそも検証していない ---
if [ "$last" = "EDIT" ]; then
  {
    printf '独立検証が済んでいません。\n'
    printf 'このセッションで実装コードを変更しましたが、最後の変更より後に crystal:verifier を呼んでいません。\n'
    printf '\n応答を終える前に、crystal:verifier サブエージェントを呼び、docs/spec/ の受け入れ条件に対する判定を受けること。\n'
    printf 'verifier は会話の経緯を引き継がず、仕様と実際の実行結果だけで判定します。\n'
    printf '\n変更した実装ファイル:\n'
    printf '%s\n' "$impl" | head -n 10 | sed 's/^/  - /'
  } >&2
  exit 2
fi

# --- 最後の印がサブエージェント起動で、コードを変更したサブエージェントの記録がある ---
if [ "$last" = "AGENT" ]; then
  if [ "$have_verify" != "1" ]; then
    # 一度も検証していない。verifier を呼べば VERIFY が最後の印になり自然に抜けられる
    {
      printf '独立検証が済んでいません。\n'
      printf 'このセッションではサブエージェントが実装コードを変更していますが、crystal:verifier を呼んでいません。\n'
      printf '実装をサブエージェントに委譲した場合も、独立検証の対象です。\n'
      printf '\n応答を終える前に、crystal:verifier サブエージェントを呼び、docs/spec/ の受け入れ条件に対する判定を受けること。\n'
    } >&2
    exit 2
  fi
  read_verdict "$verify_id"
  if [ -n "$verdict_line" ] && [ "$(verdict_token "$verdict_line")" = "FAIL" ]; then
    # 不合格のまま後続のサブエージェントを走らせても解消にはならない
    fail_block "$verdict_line"
  fi
  # 検証済み (PASS または判定行なし) の後にサブエージェントが動いている。
  # そのサブエージェントが調査専門なら再検証は不要だが、どの起動がコードを変更したかは
  # 記録からは分からない。1 度だけ差し戻し、理由の明示で通す (change-gate と同じ線引き)。
  if [ "$stop_hook_active" = "true" ]; then
    [ -n "$sub_state" ] && rm -f "$sub_state" 2>/dev/null
    exit 0
  fi
  {
    printf '検証後にサブエージェントが動いています。\n'
    printf 'このセッションにはコードを変更したサブエージェントの記録があり、最後の crystal:verifier 呼び出しより後にもサブエージェントを起動しています。\n'
    printf '\nそのサブエージェントがコードを変更したなら、crystal:verifier を再度呼ぶこと。\n'
    printf '変更していない (調査・レビューのみ) なら、その旨を報告に書いてから応答を終えれば通ります。\n'
  } >&2
  exit 2
fi

# --- 最後の印が VERIFY。その判定が合格かを見る ---
read_verdict "$verify_id"

# --- 判定行が無い ---
# verifier の応答が取れていない、または古い定義の verifier が動いている。
# ここだけは stop_hook_active を尊重して 1 度で諦める。詰ませてまで守る性質のものではなく、
# 「最後の変更より後に検証を回した」という担保は既に取れているため。
if [ -z "$verdict_line" ]; then
  if [ "$stop_hook_active" = "true" ]; then
    exit 0
  fi
  {
    printf 'crystal:verifier の判定行を読み取れませんでした。\n'
    printf 'verifier は本文の末尾に "CRYSTAL-VERDICT: PASS" または "CRYSTAL-VERDICT: FAIL <未達の条件>" を\n'
    printf '1 行返す契約です。返っていない場合、インストール済みの crystal が古い可能性があります\n'
    printf '(claude plugin update crystal@yuki)。\n'
    printf '\nverifier の報告を自分で確認し、受け入れ条件を満たしていない項目があれば修正すること。\n'
    printf '確認済みで問題なければ、そのまま応答を終えれば通ります。\n'
  } >&2
  exit 2
fi

if [ "$(verdict_token "$verdict_line")" = "PASS" ]; then
  # この検証で「未検証のサブエージェント編集」は解消された。記録を消し、
  # 以降のターンで調査エージェントを走らせただけで差し戻される状態を残さない
  [ -n "$sub_state" ] && rm -f "$sub_state" 2>/dev/null
  exit 0
fi

fail_block "$verdict_line"
