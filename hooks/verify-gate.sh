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
have_spec=0
for d in docs/spec docs/specs; do
  [ -d "$d" ] || continue
  if find "$d" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -q .; then
    have_spec=1
    break
  fi
done
[ "$have_spec" = "1" ] || exit 0

tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# --- 最後に現れた印を取る ---
# jq は JSONL の途中に壊れた行があるとその場で終了するため、行単位で読んで不正行を捨てる。
#
# サブエージェント起動ツールの名前は Claude Code のビルドによって Agent / Task の
# どちらにもなる。片方だけを見るとある日静かにゲートが無効化されるため両方受ける。
#
# 変更痕跡はコードファイルへの編集だけを数える。docs/spec/ のステータス更新や
# README の修正で「検証が無効になった」とみなすと、検証直後に必ず差し戻されて
# 抜けられなくなる。設定ファイルも同じ理由で数えない。
marker=$(jq -Rr --arg code "$CODE_RE" --arg config "$CONFIG_RE" --arg spec "$SPEC_RE" \
  --arg root "$project_dir" '
  fromjson? // empty
  | select(.type=="assistant") | .message.content[]?
  | select(.type=="tool_use")
  | if ((.name=="Task" or .name=="Agent")
        and (((.input.subagent_type // "") | test("verifier"))))
    then "VERIFY"
    elif (.name=="Write" or .name=="Edit" or .name=="MultiEdit" or .name=="NotebookEdit")
    then ((.input.file_path // "") | ltrimstr($root + "/")
          | if test($spec) then empty
            elif test($config) then empty
            elif test($code) then "EDIT"
            else empty end)
    else empty end' "$tp" 2>/dev/null | tail -n 1)

# VERIFY が最後 = 最後の変更より後に検証している
[ "$marker" = "VERIFY" ] && exit 0

# 印が 1 つも無い = このセッションはコードを触っていない (作業ツリーが元から汚れている、
# Bash 経由で書き換えた等)。このゲートの対象は「このセッションで実装した人」なので素通しする。
[ -n "$marker" ] || exit 0

{
  printf '独立検証が済んでいません。\n'
  printf 'このセッションで実装コードを変更しましたが、最後の変更より後に crystal:verifier を呼んでいません。\n'
  printf '\n応答を終える前に、crystal:verifier サブエージェントを呼び、docs/spec/ の受け入れ条件に対する判定を受けること。\n'
  printf 'verifier は会話の経緯を引き継がず、仕様と実際の実行結果だけで判定します。\n'
  printf '\n判定が「満たさない」だった条件は、修正してから再度 verifier を通すこと\n'
  printf '(修正するとその変更が最後の印になるため、再検証が必要になります)。\n'
  printf '\n変更した実装ファイル:\n'
  printf '%s\n' "$impl" | head -n 10 | sed 's/^/  - /'
} >&2
exit 2
