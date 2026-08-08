#!/bin/bash
# change-gate.sh — 変更の「対」を機械検証する Stop hook
#
# 2 つだけを見る:
#   1. 実装コードが変わったのに、テストコードが 1 つも変わっていない
#   2. 実装コードが変わったのに、docs/spec/ が 1 つも変わっていない
#
# どちらも差分の「形」だけで判定する。テストの中身が妥当か、仕様が実装と
# 合っているかは見ない(見られない)。ここが担保するのは
# 「対になるファイルを書き忘れたまま完了と報告する」ことが起きない、という一点。
#
# 散文(rules/testing.md)ではなくここに置く理由: 差分の形は機械で判定できる。
# 判定できることを散文で頼むと、コンテキストを消費して遵守率は上がらない。
set -u

input=$(cat)

# --- プロジェクトルートへ移動 ---
# `cd .` は必ず成功するため `cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0` ではガードにならず、
# CLAUDE_PROJECT_DIR 未設定時にカレント(モノレポのサブパッケージ等)を見てしまう。
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# 分類の定義は verify-gate.sh と共有する (hooks/lib/classify.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
own_marker=""
[ -n "$session_id" ] && own_marker="$(crystal_state_dir)/${session_id}.change-gate.blocked"

# --- 自分の差し戻し後の再停止では素通しする ---
# 免除(既存テストで担保されるリファクタ、仕様が変わらないバグ修正、
# 使い捨てスクリプト)は差分の形からは判定できない。免除を機械で判定しようとすると
# 誤検知でゲートごと無視されるようになるため、「1 度差し戻して理由を明示させる」形にする。
# 免除に当たるなら、その旨を報告に書いてから再度応答を終えれば通る。
#
# ただし stop_hook_active は「どれかの Stop hook が差し戻した」フラグであって、
# 自分が差し戻したかは分からない。フラグだけで素通しすると、stop-gate 等の差し戻しが
# このゲートの検査を丸ごと免除してしまう。自分の差し戻しの記録があるときだけ素通しする。
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  # session_id が取れないビルドでは従来どおりチェーン全体で素通しする (ループ防止を優先)
  [ -n "$own_marker" ] || exit 0
  if [ -f "$own_marker" ]; then
    rm -f "$own_marker" 2>/dev/null
    exit 0
  fi
  # 差し戻したのは他のゲート。このゲートの検査はまだ通っていないので続行する
fi

# --- このセッションの作業痕跡で発火を絞る ---
# 差分の形は作業ツリー全体から取るが、ツリーはセッション開始前から汚れていることがある
# (人間の書きかけ、前セッションの残り)。transcript に作業痕跡が無いターン (純粋な質問応答)
# まで差し戻すと、ゲートは「会話のたびに鳴る警報」になり無視される。
#   - 編集ツールの痕跡があれば、そのファイル群だけを実装判定の対象にする
#   - Bash 書き換えや、コードを変更したサブエージェントの記録があれば、何を触ったか
#     特定できないので従来どおりツリー全体を見る
#   - transcript が取れないビルドでは従来どおりツリー全体を見る (ゲートを黙って殺さない)
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
scope="tree"
session_rel=""
if [ -n "$tp" ] && [ -f "$tp" ]; then
  marks=$(session_work_marks "$tp")
  attributable=1
  printf '%s\n' "$marks" | grep -q '^BASH$' && attributable=0
  if [ "$attributable" = "1" ] && printf '%s\n' "$marks" | grep -q '^AGENT$'; then
    if [ -z "$session_id" ] || [ -s "$(subagent_edits_file "$session_id")" ]; then
      attributable=0
    fi
  fi
  if [ "$attributable" = "1" ]; then
    session_rel=$(printf '%s\n' "$marks" | ROOT="$project_dir/" awk -F '\t' '
      BEGIN { root = ENVIRON["ROOT"] }
      $1 == "FILE" {
        p = $2
        if (index(p, root) == 1) p = substr(p, length(root) + 1)
        print p
      }' | sort -u)
    [ -n "$session_rel" ] || exit 0 # 会話だけのターン
    scope="session"
  fi
fi

changed=$(changed_files)
[ -n "$changed" ] || exit 0

if [ "$scope" = "session" ]; then
  # 実装の判定はこのセッションが編集したファイルに限る。テスト・spec の対は
  # ツリー全体から探す (人間が先にテストを書いてある TDD を差し戻さないため)
  impl=$(impl_files "$(printf '%s\n' "$changed" | grep -Fxf <(printf '%s\n' "$session_rel"))")
else
  impl=$(impl_files "$changed")
fi
[ -n "$impl" ] || exit 0

specs=$(printf '%s\n' "$changed" | grep -E "$SPEC_RE")
# docs/spec/ は TEST_RE の `specs?/` にも一致してしまうため、先に除く。
# 除かないと、仕様を書いただけでテストも書いたことになり、テスト側のゲートが死ぬ。
tests=$(printf '%s\n' "$changed" | grep -E "$TEST_RE" | grep -Ev "$SPEC_RE")

# プロジェクト単位で切れるようにしておく。
# 切れないゲートは、合わない現場では plugin ごと外されて全部が失われる。
findings=""
if [ "${CRYSTAL_TEST_GATE:-on}" != "off" ] && [ -z "$tests" ]; then
  findings="${findings}
- 対になるテストコードの変更がありません。実装と同じ変更でテストを追加・更新すること (rules/testing.md)。"
fi
if [ "${CRYSTAL_SPEC_GATE:-on}" != "off" ] && [ -z "$specs" ]; then
  findings="${findings}
- 対になる docs/spec/ の変更がありません。/crystal:spec で仕様を作成・更新してから実装すること。"
fi
[ -n "$findings" ] || exit 0

# 自分が差し戻したことを記録する (再停止で自分の分だけを素通しするため)
if [ -n "$own_marker" ]; then
  mkdir -p "$(dirname "$own_marker")" 2>/dev/null && touch "$own_marker" 2>/dev/null
fi

{
  printf '変更の対が揃っていません。以下を満たすまで完了と報告しないこと。%s\n' "$findings"
  printf '\n変更された実装ファイル:\n'
  printf '%s\n' "$impl" | head -n 10 | sed 's/^/  - /'
  n=$(printf '%s\n' "$impl" | grep -c .)
  [ "$n" -gt 10 ] && printf '  ... 他 %s 件\n' "$((n - 10))"
  printf '\n免除に当たる場合 (既存テストで担保されるリファクタ / 仕様が変わらないバグ修正 /\n'
  printf '使い捨てスクリプト) は、どれに当たるかを報告に明記すれば、次の応答終了で通ります。\n'
} >&2
exit 2
