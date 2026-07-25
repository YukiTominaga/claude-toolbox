#!/bin/bash
# stop-gate.sh — 完了宣言時の検証ゲート
# Claude が応答を終えようとしたとき、リポジトリに変更があれば L1 検証を実行し、
# 失敗していれば exit 2 で差し戻す。検証の中身は scripts/project-checks.sh にある。
#
# ゴール(.claude/goal.md)が動いているセッションでは goal-gate が毎ラウンド同じ検証を行うが、
# **このフックは goal.md を読まない**。双方が同じファイルを別々に解釈してズレると
# 「どちらも検証しない」に倒れるため。読まなければ最悪でも「二重実行(無駄)」に倒れる。
#
# 差し戻し後の再停止 (stop_hook_active: true) でも検証する。ここを素通しにすると、
# goal.md の無いセッションでは一度差し戻された時点で L1 が二度と走らなくなる。
# 暴走防止は「連鎖内で通算 MAX_PUSHBACK 回まで」というカウントが担う。
set -u

MAX_PUSHBACK=3

# --- プラグインルートの解決は cd より前に行う ---
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

input=$(cat)
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# --- git 管理下でなければ対象外 ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

STATE_DIR=".claude/loop"
STATE="$STATE_DIR/stop-gate-pushback"
# 一時ファイルは置換先と同じディレクトリに置く(別ディレクトリだと rename が原子的でない)。
# 接尾辞の PID は、同じプロジェクトで並行するフック同士の衝突を避けるためだけのもの。
TMP="$STATE.$$.tmp"

# カウントの書き込みは必ずこれを通す。`printf > "$STATE"` の直書きは
# 「ファイルを空にする」と「値を書く」の 2 段階で、その隙間に読んだ側は空文字列を得て
# count=0 に丸める。差し戻し上限はカウントが読めることだけに依存しているので、
# 丸められると歯止めが黙って消える。
#
# **書き込みが成功したときだけ置換する**ことが本体で、一時ファイルを経由すること自体ではない。
# ENOSPC 等で write が途中で失敗しても、既存の値はそのまま残る (S-8)。
# 置換先を unlink してから作り直してはいけない。ファイルが存在しない窓が開き、
# その間に読んだ側は cat に失敗して同じく 0 に丸める。
write_count() { # $1=書き込む値
  if printf '%s\n' "$1" >"$TMP" 2>/dev/null && mv -f "$TMP" "$STATE" 2>/dev/null; then
    return 0
  fi
  rm -f "$TMP" 2>/dev/null
  return 1
}

# --- 連鎖が切れた合図を最優先で処理する ---
# stop_hook_active: false は「前の差し戻し連鎖が終わった」という意味なので、
# **変更判定より前に**カウントを 0 に戻す。後ろに置くと、auto-commit が作業ツリーを
# 空にする運用では clean な false 停止が常態になり、カウントが次の連鎖へ持ち越される。
# その結果、一度も差し戻していない連鎖の初回停止で L1 を飛ばし、
# 事実に反する「差し戻し上限に達した」を出す(独立検証が捕まえた欠陥)。
#
# ファイルが無ければカウントは実質 0 なので何もしない。ここで作らないことで、
# ループを使っていないプロジェクトに .claude/loop/ を生やさずに済む。
#
# 書けない環境ではリセットも失敗するが、それでよい。下の事前判定が同じ理由で失敗して
# count="" になり、上限判定そのものを行わなくなるため、古い値が残っても実害は出ない。
if [ "$active" != "true" ] && [ -f "$STATE" ]; then
  write_count 0
fi

# --- 変更がなければゲート不要(質問応答セッション等) ---
# カウントの置き場である .claude/loop は変更判定から除外する。含めると、記帳しただけの
# セッションが「変更あり」になり検証が走る。.gitignore に頼らないのは goal-gate と同じ理由。
own=":(exclude).claude/loop"
if git diff --quiet HEAD -- . "$own" 2>/dev/null \
  && git diff --cached --quiet -- . "$own" 2>/dev/null \
  && [ -z "$(git ls-files --others --exclude-standard -- . "$own")" ]; then
  exit 0
fi

CHECKS="$ROOT/scripts/project-checks.sh"
[ -x "$CHECKS" ] || exit 0

# --- 差し戻し回数のカウント ---
# 書けない環境ではカウントできない。差し戻すと上限が効かず無限ループになるので、
# 往復中 (active) だけは従来どおり素通しする。初回停止は数えなくても 1 回で済むので検証する。
#
# 判定は**実際の書き込み経路と同じ条件**で行う。以前は `: >>"$STATE"` で既存ファイルへの
# 追記オープンを見ていたが、これはディレクトリが読み取り専用でもファイルさえ書ければ成功する。
# 実経路は一時ファイルの新規作成を要求するので、「書けると判定したのに書けない」が起きていた。
# リダイレクト失敗のメッセージは `>file 2>/dev/null` では消えない(順序の都合)ので先に閉じる
if ! mkdir -p "$STATE_DIR" 2>/dev/null || ! : 2>/dev/null >"$TMP"; then
  [ "$active" = "true" ] && exit 0
  count=""
else
  rm -f "$TMP" 2>/dev/null # 判定に使っただけなので残さない

  # false は「連鎖が切れた」合図としてのみ使う(戻ってこない環境でも上限は効く)。
  if [ "$active" = "true" ]; then
    count=$(cat "$STATE" 2>/dev/null)
    case "$count" in '' | *[!0-9]*) count=0 ;; esac
  else
    count=0
  fi

  if [ "$count" -ge "$MAX_PUSHBACK" ]; then
    printf '{"systemMessage":"stop-gate: 差し戻し上限 (%s 回) に達したため検証を打ち切りました。L1 が赤のままの可能性があります。scripts/project-checks.sh を手で確認してください。"}\n' \
      "$MAX_PUSHBACK"
    exit 0
  fi
fi

if ! failed=$("$CHECKS" 2>&1); then
  [ -n "$count" ] && write_count "$((count + 1))"
  printf '検証ゲート失敗。以下のエラーを修正するまで完了と報告しないこと。修正後は実際のコマンド出力を根拠として提示すること。\n%s\n' "$failed" >&2
  exit 2
fi

# 緑でもカウントは減らさない(赤緑の往復で上限に到達しなくなるのを防ぐ)。
# リセットは stop_hook_active: false のときだけ。
[ -n "$count" ] && [ "$active" != "true" ] && write_count 0

exit 0
