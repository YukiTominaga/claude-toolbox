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

# --- 差し戻し後の再停止では素通しする ---
# 免除(既存テストで担保されるリファクタ、仕様が変わらないバグ修正、
# 使い捨てスクリプト)は差分の形からは判定できない。免除を機械で判定しようとすると
# 誤検知でゲートごと無視されるようになるため、「1 度差し戻して理由を明示させる」形にする。
# 免除に当たるなら、その旨を報告に書いてから再度応答を終えれば通る。
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

# --- プロジェクトルートへ移動 ---
# `cd .` は必ず成功するため `cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0` ではガードにならず、
# CLAUDE_PROJECT_DIR 未設定時にカレント(モノレポのサブパッケージ等)を見てしまう。
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --- 変更ファイルの一覧 (作業ツリー + index + 未追跡) ---
# 初回コミット前は HEAD が無く `git diff HEAD` が失敗するが、未追跡分だけで判定できる。
changed=$(
  {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sed '/^$/d' | sort -u
)
[ -n "$changed" ] || exit 0

# テストコードとみなすパス。
# 実装をテスト扱いに誤分類すると差し戻しが甘くなるだけなので、広めに取る。
TEST_RE='(^|/)(tests?|__tests__|specs?|e2e)/'
TEST_RE="${TEST_RE}|(^|/)test_[^/]*\.[A-Za-z0-9]+\$"
TEST_RE="${TEST_RE}|[._-](test|spec)\.[A-Za-z0-9]+\$"
TEST_RE="${TEST_RE}|(^|/)conftest\.py\$"
TEST_RE="${TEST_RE}|Tests?\.(java|kt|cs|scala)\$"

# 設定ファイルは実装にもテストにも数えない。
# ここを実装に数えると、lint 設定を 1 行直しただけでテストを要求してしまう。
CONFIG_RE='(^|/)[^/]*\.config\.[A-Za-z0-9]+$'
CONFIG_RE="${CONFIG_RE}|(^|/)\.[A-Za-z0-9]+rc(\.[A-Za-z0-9]+)?\$"

# 実装コードとみなす拡張子
IMPL_RE='\.(ts|tsx|js|jsx|mjs|cjs|py|go|rs|rb|java|kt|kts|swift|m|mm|c|cc|cpp|cxx|h|hpp|cs|scala|php|ex|exs|dart|vue|svelte|sh|bash|zsh)$'

SPEC_RE='^docs/specs?/.+\.md$'

impl=$(printf '%s\n' "$changed" | grep -E "$IMPL_RE" | grep -Ev "$TEST_RE" | grep -Ev "$CONFIG_RE")
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
