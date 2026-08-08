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
# cp / mv / rsync は「生成したファイルを配置する」普通のワークフローで、
# sed -i と同じくファイルを書き換える。find -exec / xargs 経由の sed -i も同様
# (敵対的レビューでこの 4 系統が丸ごと素通りしていた)。
# 検出できない既知の残り: インタープリタのスクリプト実行によるファイル生成
# (`python gen.py --out src/a.ts` 等)。コマンド文字列からは書き込みの有無が分からない。
BASH_WRITE_RE='(^|[;&|(]|&&)[[:space:]]*(sudo[[:space:]]+)?(sed[[:space:]]+-[a-zA-Z]*i|perl[[:space:]]+-[a-zA-Z]*i|tee|patch|install|dd|cp|mv|rsync|truncate|ln)([[:space:]]|$)'
BASH_WRITE_RE="${BASH_WRITE_RE}|(^|[;&|(]|&&)[[:space:]]*(sudo[[:space:]]+)?(find|xargs)[[:space:]]([^;&|]*[[:space:]])?(sed|perl)[[:space:]]+-[a-zA-Z]*i"
BASH_WRITE_RE="${BASH_WRITE_RE}|>>?[[:space:]]*[^&]|git[[:space:]]+(apply|checkout|restore|revert|merge|cherry-pick|pull|rebase|stash[[:space:]]+pop)"

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

# セッション開始時点の HEAD の記録 (record-baseline.sh が SessionStart で書く)。
# ゲートが「作業ツリーの汚れ」だけを見ていると、応答を終える前に git commit する
# だけで差分が消え、change-gate / verify-gate / stop-gate が全て沈黙する
# (敵対的レビューで実証された迂回経路)。基点をセッション開始時点に固定し、
# セッション中に commit された変更も判定対象に含める。
session_baseline_file() { # $1 = session_id
  printf '%s/%s.baseline' "$(crystal_state_dir)" "$1"
}

# 記録済みのベースライン commit を出力する。使えないときは何も出力しない
# (呼び出し側は changed_files のフォールバック = HEAD 比較になる)。
session_baseline() { # $1 = session_id (空を許す)
  [ -n "${1:-}" ] || return 0
  local f c
  f=$(session_baseline_file "$1")
  [ -f "$f" ] || return 0
  c=$(cat "$f" 2>/dev/null)
  [ -n "$c" ] || return 0
  # 記録が別リポジトリのものだったり、履歴の書き換えで消えていたら使わない
  git cat-file -e "${c}^{commit}" 2>/dev/null || return 0
  printf '%s' "$c"
}

# 標準入力のダイジェスト (状態ファイルへの記録・比較用。暗号強度は不要)
crystal_digest() {
  cksum | awk '{print $1 "-" $2}'
}

# 作業ツリー全体の状態 (HEAD + 追跡差分 + 未追跡ファイルの中身) のダイジェスト。
# ベースライン方式では検証済みの変更がセッション中ずっと差分として残るため、
# stop-gate はこれで「前回検証した状態と同一か」を判定し、会話だけのターンで
# 毎回フルテストが走るのを避ける。
tree_digest() {
  {
    git rev-parse HEAD 2>/dev/null
    git status --porcelain 2>/dev/null
    git diff HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
      cksum "$f" 2>/dev/null
    done
  } | crystal_digest
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
      # 部分一致 ("verifier" を含む) にすると、判定行の契約を持たない他所の
      # 「my-verifier-x」のような別エージェントで VERIFY 印が立ってしまう。
      # 名前そのもの、またはプラグイン接頭辞付き (crystal:verifier) だけを認める
      then (if ((.input.subagent_type // "") | test("(^|[:/])verifier$"))
            then "VERIFY\t" + (.id // "")
            else "AGENT" end)
      elif (.name=="Bash" and ((.input.command // "") | test($bashwrite)))
      then "BASH"
      else empty end' "$1" 2>/dev/null
}

# 変更ファイルの一覧 (作業ツリー + index + 未追跡 + ベースラインからの commit 済み差分)。
# $1 にベースライン commit を渡すと、セッション中に commit された変更も含める
# (渡さない・空なら従来どおり HEAD 比較 = fail-open)。
# 初回コミット前は HEAD が無く `git diff HEAD` が失敗するが、未追跡分だけで判定できる。
changed_files() { # $1 = 比較の基点 (省略時 HEAD)
  local base="${1:-HEAD}"
  {
    git diff --name-only "$base" 2>/dev/null
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sed '/^$/d' | sort -u
}

# $1 の一覧から実装コードだけを取り出す
impl_files() {
  printf '%s\n' "$1" | grep -E "$IMPL_RE" | grep -Ev "$TEST_RE" | grep -Ev "$CONFIG_RE"
}
