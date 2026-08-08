#!/bin/bash
# subagent-gate.sh — サブエージェントの完了報告の裏取りゲート
#
# サブエージェントが「テストが通った」等の検証済みの主張をしているのに、
# そのサブエージェントの transcript に検証コマンドを実行した痕跡がない場合、
# exit 2 で差し戻して実際に実行させる。
#
# ここでフル検証 (typecheck / test) は行わない(意図的な設計):
# Workflow の並列エージェントは既定で worktree 隔離されず同一チェックアウトを共有するため、
# 十数本が同時に npm test を叩くとキャッシュ破壊と CPU 飽和を招く。
# プロジェクト全体の検証は親の Stop (stop-gate.sh) に一本化する。
# ファイル単位の lint / 整形は PostToolUse (lint-changed.sh / format-on-save.sh) が
# サブエージェント内でも発火するため、ここでは重複させない。
set -u

# 正規表現の .{0,N} はロケール依存(C ロケールではバイト数になり、日本語では
# 13文字程度で頭打ちになる)。判定を環境非依存にするため UTF-8 ロケールに固定する
if [ -z "${LC_ALL:-}" ]; then
  for _loc in en_US.UTF-8 C.UTF-8; do
    if locale -a 2>/dev/null | grep -qxi "$_loc"; then
      export LC_ALL="$_loc"
      break
    fi
  done
fi

input=$(cat)

# --- 差し戻し後の再停止では素通し(無限ループ防止。ランタイム側にもブロック上限がある) ---
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

msg=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty' 2>/dev/null)
[ -n "$msg" ] || exit 0

# --- 検証済みを主張しているか。していなければ対象外 ---
# ブラケット式にマルチバイト文字を入れると BSD grep が
# "brackets not balanced" で落ちるため、否定文字クラスは使わない。
# 結果語は活用形まで要求する: 裸の「通り」は「以下の通り」「次の通り」に一致してしまい、
# 検証を主張していない調査エージェントを差し戻す誤検知になる。
CLAIM_RE='(テスト|test|typecheck|型チェック|lint|リント|ビルド|build|pytest|vitest|jest|tsc|eslint|ruff).{0,40}(通っ|通過|通りまし|通ります|パスし|成功し|成功です|クリーンで|エラーなし|エラーはなし|問題なし|green|passed|passing|all tests pass)'
printf '%s' "$msg" | grep -qiE "$CLAIM_RE" || exit 0

# --- そのサブエージェントが実際に実行したコマンドを集める ---
tp=$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null)
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

# --- 何も変更していないエージェントは対象外 ---
# 裏取りが要るのは「変更したうえで検証済みだと報告する」エージェントだけ。
# CLAIM_RE は一人称の完了報告と、他人のコードについての説明文を区別できない
# (例:「stop-gate.sh はテスト・型チェック・lint を実行し、通っていれば素通しする」は一致する)。
# 調査・レビュー専門のエージェントは定義上ファイルを触らないため、変更痕跡の有無で切り分ける。
# 代償: 何も変更していないエージェントの偽りの検証主張は素通しするが、
# 何も壊していない以上、調査結果を丸ごと失わせるより害が小さい。
# Bash 書き換えの検出規則は他の hook と共有する (hooks/lib/classify.sh の BASH_WRITE_RE)
. "$(dirname "${BASH_SOURCE[0]}")/lib/classify.sh"

edits=$(jq -Rr --arg bashwrite "$BASH_WRITE_RE" 'fromjson? // empty
  | select(.type=="assistant") | .message.content[]?
  | select(.type=="tool_use")
  | if (.name=="Write" or .name=="Edit" or .name=="MultiEdit" or .name=="NotebookEdit")
    then .name
    # Bash 経由の書き換え(sed -i / tee / リダイレクト / patch 等)も変更とみなす。
    # 編集ツールを使わずにファイルを書き換えたエージェントを取りこぼさないため
    elif .name=="Bash" and ((.input.command // "") | test($bashwrite))
    then "Bash"
    else empty end' "$tp" 2>/dev/null)
[ -n "$edits" ] || exit 0

# jq は JSONL の途中に壊れた行があるとその場で終了するため、行単位で読んで不正行を捨てる
commands=$(jq -Rr 'fromjson? // empty
  | select(.type=="assistant") | .message.content[]?
  | select(.type=="tool_use" and .name=="Bash") | .input.command // empty' "$tp" 2>/dev/null)

# コマンドの先頭(または ; && || | ( の直後)にのみ一致させる。
# 部分一致にすると git commit -m "npm test が落ちる" のような、
# 検証コマンドを文字列として含むだけのコマンドでゲートを素通りできてしまう
VERIFY_SEP='(^|[;&|(]|&&|\|\|)[[:space:]]*(sudo[[:space:]]+)?'
# Python 系はランナー経由の実行が標準的 (uv run pytest / poetry run pytest /
# python -m pytest)。プレフィックスを認めないと、正当に検証したエージェントを
# 差し戻す誤検知になる。プレフィックス単体では通らない (後続に検証コマンドが要る)
VERIFY_RUNNER='((uv|poetry|pipenv)[[:space:]]+run[[:space:]]+|python3?[[:space:]]+-m[[:space:]]+)?'
VERIFY_CMD='((npm|pnpm|yarn|bun)[[:space:]]+(run[[:space:]]+)?(test|lint|typecheck|type-check|build|check)'
VERIFY_CMD="${VERIFY_CMD}|npx[[:space:]]+(--no-install[[:space:]]+)?(vitest|jest|tsc|eslint|prettier|playwright|mocha)"
VERIFY_CMD="${VERIFY_CMD}|(vitest|jest|pytest|tsc|eslint|ruff|mypy|shellcheck|rspec|phpunit)([[:space:]]|$)"
VERIFY_CMD="${VERIFY_CMD}|go[[:space:]]+(test|vet)|cargo[[:space:]]+(test|check|clippy)"
VERIFY_CMD="${VERIFY_CMD}|make[[:space:]]+(test|check|lint)|bash[[:space:]]+-n|gradle[[:space:]]+(test|check)|mvn[[:space:]]+(test|verify))"

if printf '%s' "$commands" | grep -qiE "${VERIFY_SEP}${VERIFY_RUNNER}${VERIFY_CMD}"; then
  exit 0
fi

# --- 検証を主張しているのに実行痕跡がない → 差し戻し ---
LOG_DIR="$HOME/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null
# grep -c は不一致でも 0 を出力して exit 1 になるため、|| によるフォールバックは付けない
n_cmds=$(printf '%s' "$commands" | grep -c . 2>/dev/null)
case "$n_cmds" in '' | *[!0-9]*) n_cmds=0 ;; esac
printf '{"ts":"%s","agent_id":"%s","agent_type":"%s","blocked":true,"bash_calls":%s}\n' \
  "$(date -Iseconds)" \
  "$(printf '%s' "$input" | jq -r '.agent_id // ""' 2>/dev/null)" \
  "$(printf '%s' "$input" | jq -r '.agent_type // ""' 2>/dev/null)" \
  "$n_cmds" \
  >>"$LOG_DIR/subagent-gate.jsonl" 2>/dev/null

{
  printf '完了報告の裏取りに失敗しました。\n'
  printf 'あなたは「テスト / lint / 型チェック / ビルドが通った」旨を報告していますが、あなたの実行履歴に対応するコマンドの実行が見つかりません。\n'
  printf '次のいずれかを行ってから応答を終えること:\n'
  printf '  1. 実際に検証コマンドを実行し、その出力を報告に含める\n'
  printf '  2. 実行していないのであれば、その旨を明示して報告を訂正する(「未検証」と書く)\n'
  printf '検証していないものを検証済みとして親エージェントに返さないこと。\n'
} >&2
exit 2
