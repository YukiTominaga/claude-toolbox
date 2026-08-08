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

# Bash コマンドによるファイル書き換えの可能性の検出 (jq の test() に渡す)。
# subagent-gate.sh と session_work_marks() が共有する。
# 部分一致にせずコマンド先頭 (または ; && || | ( の直後) にのみ当てる。
BASH_WRITE_RE='(^|[;&|(]|&&)[[:space:]]*(sudo[[:space:]]+)?(sed[[:space:]]+-[a-zA-Z]*i|perl[[:space:]]+-[a-zA-Z]*i|tee|patch|install|dd)([[:space:]]|$)|>>?[[:space:]]*[^&]|git[[:space:]]+(apply|checkout|restore|revert|stash[[:space:]]+pop)'

# ゲート間で共有する状態の置き場。
# stop_hook_active はチェーン内のどの Stop hook が差し戻しても立つため、
# 「自分が差し戻した再停止か」はフラグからは分からない。各ゲートが自分の差し戻しを
# ここに記録し、自分の記録がある再停止だけを素通しする (他ゲートの差し戻しでは検査を行う)。
# サブエージェントによるコード変更の記録 (record-subagent-edits.sh) も同じ場所に置く。
crystal_state_dir() {
  printf '%s/state/crystal' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# セッション中にコードを変更したサブエージェントの記録ファイル。
# record-subagent-edits.sh (SubagentStop) が書き、Stop 側のゲートが読む。
# verify-gate.sh が PASS を受理した時点で消す。
subagent_edits_file() { # $1 = session_id
  printf '%s/%s.subagent-code-edits' "$(crystal_state_dir)" "$1"
}

# メイン transcript からセッションの作業痕跡を時系列の印として出す:
#   FILE\t<path>  編集ツールによる書き換え (パスは記録どおり = 通常は絶対パス)
#   BASH          Bash によるファイル書き換えの可能性があるコマンド
#   AGENT         verifier 以外のサブエージェント起動 (何を編集したかはここからは分からない)
#   VERIFY\t<id>  crystal:verifier の起動 (id は tool_use id。戻り値の判定行を引くのに使う)
# サブエージェント起動ツールの名前はビルドにより Agent / Task の両方がある。
# jq は JSONL の途中に壊れた行があるとその場で終了するため、行単位で読んで不正行を捨てる。
session_work_marks() { # $1 = transcript path
  jq -Rr --arg bashwrite "$BASH_WRITE_RE" '
    fromjson? // empty
    | select(.type=="assistant") | .message.content[]?
    | select(.type=="tool_use")
    | if (.name=="Write" or .name=="Edit" or .name=="MultiEdit" or .name=="NotebookEdit")
      then "FILE\t" + (.input.file_path // "")
      elif (.name=="Task" or .name=="Agent")
      then (if ((.input.subagent_type // "") | test("verifier"))
            then "VERIFY\t" + (.id // "")
            else "AGENT" end)
      elif (.name=="Bash" and ((.input.command // "") | test($bashwrite)))
      then "BASH"
      else empty end' "$1" 2>/dev/null
}

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
