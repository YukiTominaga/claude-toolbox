# classify.sh — 変更ファイルの分類。change-gate.sh と verify-gate.sh が source する。
#
# 2 つのゲートに正規表現を書き写すと、必ず片方だけ直された状態が生まれる
# (このリポジトリでは実際に、CRLF 対応が 3 つのパーサのうち 1 つだけ直っていた)。
# 分類の定義はここ 1 箇所に置く。
#
# 単体では実行しない。呼び出し側が `. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"` する。

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

# 実装かテストか、いずれにせよ「コード」とみなすもの。
# transcript 上の編集ツールの file_path を判定するのに使う。
#
# 単体では使わないこと: TEST_RE の `specs?/` が docs/spec/ に一致するため、
# CONFIG_RE と SPEC_RE を先に除いてから当てる必要がある。
# また file_path は絶対パスで記録されるので、プロジェクトルートを剥がしてから当てること
# (剥がさないと `/home/me/specs/proj/src/a.ts` のような親ディレクトリ名に引きずられる)。
CODE_RE="${IMPL_RE}|${TEST_RE}"

# 変更ファイルの一覧 (作業ツリー + index + 未追跡)。
# 初回コミット前は HEAD が無く `git diff HEAD` が失敗するが、未追跡分だけで判定できる。
changed_files() {
  {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sed '/^$/d' | sort -u
}

# $1 の一覧から実装コードだけを取り出す
impl_files() {
  printf '%s\n' "$1" | grep -E "$IMPL_RE" | grep -Ev "$TEST_RE" | grep -Ev "$CONFIG_RE"
}
