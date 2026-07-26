#!/bin/bash
# goal-gate.sh — ゴール達成の自動判定ゲート (Loop Engineering の /goal 相当)
# Claude が応答を終えようとしたとき、.claude/goal.md (status: active) があれば
# Haiku で完了条件の達成を判定し、未達なら exit 2 で差し戻す。
#
# stop-gate.sh と異なり stop_hook_active では素通ししない(意図的な差異):
# 差し戻し後の再停止でも毎回判定するのがこのゲートの目的であり、
# 無限ループ防止は round カウンタ + max_rounds が担う。
set -u

# --- 再帰防止: 内側の claude -p (judge) から起動された場合は素通し ---
if [ "${CRYSTAL_GOAL_JUDGE:-}" = "1" ]; then
  exit 0
fi

input=$(cat)

# --- プロジェクトルートへ移動 ---
# `cd .` は必ず成功するため `cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0` ではガードにならず、
# CLAUDE_PROJECT_DIR 未設定時にカレント次第で .claude/goal.md を見失う。
# 未設定なら git のトップレベルにフォールバックする。
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0

GOAL=".claude/goal.md"
[ -f "$GOAL" ] || exit 0

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/goal-gate.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null

warn() {
  printf '{"ts":"%s","level":"warn","msg":"%s"}\n' "$(date -Iseconds)" "$1" >>"$LOG" 2>/dev/null
}

# 移植性のあるタイムアウト。macOS には coreutils の timeout が無いため perl で代替する
# (timeout が無い環境では judge が exit 127 で必ず失敗し、判定に到達できなくなる)
run_with_timeout() {
  _secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$_secs" "$@"
  else
    "$@"
  fi
}

# frontmatter の区切りは /^---[[:space:]]*$/ で判定する。厳密一致にすると
# CRLF 改行の goal.md で frontmatter を見失い、ゲートが黙って無効化されるため。

# frontmatter の値を取得(行末コメント・前後空白・CR を除去)
get_field() {
  awk -v k="$1" '
    /^---[[:space:]]*$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" {
      sub("^"k": *", ""); sub(" *#.*$", ""); gsub(/\r/, ""); gsub(/^ +| +$/, ""); print; exit
    }' "$GOAL"
}

# frontmatter の値を書き換える。フィールドが無ければ閉じ --- の直前に追加する
# (旧テンプレートで作られた goal.md にも cost_usd を書けるようにするため)
# 書けなかった場合は非ゼロを返す。呼び出し側は必ず戻り値を見ること:
# round の永続化に失敗したまま進むと、max_rounds に永遠に到達せず無限に差し戻し続ける。
update_field() {
  _tmp=$(mktemp "${GOAL}.XXXXXX" 2>/dev/null) || return 1
  if awk -v k="$1" -v v="$2" '
    /^---[[:space:]]*$/ {
      fm++
      if (fm==2 && !written) { print k": "v; written=1 }
      print; next
    }
    fm==1 && $0 ~ "^"k":" { print k": "v; written=1; next }
    { print }
    END { exit(written ? 0 : 1) }' "$GOAL" >"$_tmp"; then
    mv "$_tmp" "$GOAL"
  else
    rm -f "$_tmp"
    return 1
  fi
}

# judge の自由記述を Markdown の1行に収める。
# 改行が入ると awk が "newline in string" で落ち、判定履歴の追記が丸ごと失われる。
sanitize_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# 見出し "## <名前>" 直下のセクション本文を取り出す
get_section() {
  awk -v h="## $1" 'index($0,h)==1 { f=1; next } /^## / { f=0 } f' "$GOAL"
}

# --- frontmatter が壊れている goal.md には触らない ---
# 開始/終了の --- が揃っていないと update_field が黙って何も書けず、
# round が永続化されないまま差し戻しだけが続く
fm_ok=$(awk '
  NR==1 && /^---[[:space:]]*$/ { s=1; next }
  s && /^---[[:space:]]*$/ { e=1; exit }
  END { print (s && e) ? "1" : "0" }' "$GOAL")
if [ "$fm_ok" != "1" ]; then
  warn "goal.md の frontmatter が不正なため判定をスキップ"
  exit 0
fi

status=$(get_field status)
[ "$status" = "active" ] || exit 0

# --- claude CLI の有無はラウンドを消費する前に確認する ---
# (判定できない環境でラウンドだけ減り、判定ゼロのまま stalled に落ちるのを防ぐ)
command -v claude >/dev/null 2>&1 || {
  warn "claude CLI が見つからないため判定をスキップ"
  exit 0
}

round=$(get_field round)
max_rounds=$(get_field max_rounds)
case "$round" in '' | *[!0-9]*) round=0 ;; esac
case "$max_rounds" in '' | *[!0-9]*) max_rounds=5 ;; esac
# 桁あふれで $((round + 1)) が負値になり上限判定をすり抜けるのを防ぐ
[ "${#round}" -gt 9 ] && round=0
[ "${#max_rounds}" -gt 9 ] && max_rounds=5

# --- 判定前にラウンドを進めて永続化(判定がクラッシュしてもカウントを失わない) ---
round=$((round + 1))
if ! update_field round "$round"; then
  warn "round の永続化に失敗したため判定をスキップ (frontmatter 不正または書き込み不可)"
  exit 0
fi

if [ "$round" -gt "$max_rounds" ]; then
  update_field status stalled
  printf '{"systemMessage":"goal-gate: ラウンド上限 (%s) に達したため自動判定を停止しました (status: stalled)。/crystal:goal status で判定履歴を確認し、条件を見直して /crystal:goal resume で再開してください。実態の確認には crystal:verifier が使えます。"}\n' "$max_rounds"
  exit 0
fi

# --- 判定材料の収集 ---
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

context=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  context=$(tail -n 300 "$transcript_path" |
    jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null |
    tail -c 6000)
fi
gitinfo=$(git status --short 2>/dev/null | head -n 30)
conditions=$(get_section "完了条件")
constraints=$(get_section "制約")

prompt="あなたはゴール達成の判定器です。以下の完了条件・制約・直近の作業ログ・git status を読み、完了条件がすべて満たされたかを判定してください。
出力は次の JSON のみ。説明文・コードフェンスは一切付けないこと:
{\"met\": true|false, \"unmet\": [\"未達の条件ID\"], \"violations\": [\"違反した制約ID\"], \"reason\": \"簡潔な理由\"}

判定の原則:
- あなたは作業ログに書かれた内容しか読めない。コマンドを実行することも、ファイルを直接読むこともできない
- 各条件に併記された検証コマンドの実際の出力が作業ログに現れていない条件は、未達として扱うこと
- 判定できない条件・情報が足りない条件は未達として扱うこと
- 制約に違反していると判断した場合は violations に制約IDを入れること。violations が空でなければ met は false にすること
- アプリケーションコードを変更したのに、テストの追加・更新とその実行結果が作業ログに現れていない場合は未達として扱うこと。ただしドキュメント・設定のみの変更、および既存テストで担保されるリファクタは除く

## 完了条件
${conditions}

## 制約
${constraints}

## 直近の作業ログ (assistant 出力の末尾)
${context}

## git status --short
${gitinfo}"

# --- Haiku による判定 (再帰防止は disableAllHooks + env ガードの二重化) ---
raw=$(printf '%s' "$prompt" | CRYSTAL_GOAL_JUDGE=1 \
  run_with_timeout 120 claude -p --output-format json \
  --model claude-haiku-4-5-20251001 \
  --settings '{"disableAllHooks": true}' 2>>"$LOG") || {
  warn "judge 実行失敗 (round=$round)"
  exit 0
}

# --output-format json のエンベロープから本文とコストを取り出す
result=$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null)
[ -n "$result" ] || result="$raw"
cost=$(printf '%s' "$raw" | jq -r '.total_cost_usd // empty' 2>/dev/null)

# --- 累積コストの更新 (judge の消費を可視化する。記事のコスト爆発対策) ---
# jq は小さい値を 1e-05 の科学記法で出すため、それも受け付ける。
# 逆に 0.1.2 のような不正値は弾く(通すと累積が静かに狂い、ログ行も欠落する)
NUM_RE='^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$'
printf '%s' "$cost" | grep -qE "$NUM_RE" || cost=""
if [ -n "$cost" ]; then
  cur=$(get_field cost_usd)
  printf '%s' "$cur" | grep -qE "$NUM_RE" || cur=0
  update_field cost_usd "$(awk -v a="$cur" -v b="$cost" 'BEGIN{ printf "%.4f", a+b }')" || true
fi

json=$result
if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  json=$(printf '%s' "$result" | sed -n '/{/,/}/p')
fi
met=$(printf '%s' "$json" | jq -r '.met' 2>/dev/null)
if [ "$met" != "true" ] && [ "$met" != "false" ]; then
  warn "judge 出力のパースに失敗 (round=$round)"
  exit 0
fi

unmet=$(sanitize_line "$(printf '%s' "$json" | jq -r '(.unmet // []) | join(", ")' 2>/dev/null)")
violations=$(sanitize_line "$(printf '%s' "$json" | jq -r '(.violations // []) | join(", ")' 2>/dev/null)")
reason=$(sanitize_line "$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null)")

# --- 制約違反があれば達成扱いにしない (ゴールドリフト対策) ---
if [ -n "$violations" ]; then
  met=false
fi

# --- 判定履歴を記録 (/learn の素材) ---
printf '%s' "$json" | jq -c \
  --arg ts "$(date -Iseconds)" --arg sid "$session_id" --argjson r "$round" \
  --arg met "$met" --arg cost "${cost:-0}" \
  '{ts:$ts, session_id:$sid, round:$r, met:($met=="true"), unmet:(.unmet // []), violations:(.violations // []), reason:(.reason // ""), cost_usd:($cost|tonumber?)}' \
  >>"$LOG" 2>/dev/null

# --- goal.md の「## 判定履歴」に追記 (直近5件。次ターン以降が読む外部メモリ) ---
if [ "$met" = "true" ]; then
  entry="- r${round}: 達成 — ${reason}"
else
  entry="- r${round}: 未達 [${unmet:-?}]${violations:+ 制約違反 [$violations]} — ${reason}"
fi
# entry は ENVIRON 経由で渡す: awk の -v は値のエスケープを展開してしまい、
# reason に \t や \n が含まれると文字列が壊れる(改行なら awk 自体が落ちる)
_hist_tmp=$(mktemp "${GOAL}.XXXXXX" 2>/dev/null) &&
  GG_ENTRY="$entry" awk -v keep=5 '
  BEGIN { entry = ENVIRON["GG_ENTRY"] }
  { lines[NR]=$0 }
  END{
    start=0
    for (i=1; i<=NR; i++) if (index(lines[i],"## 判定履歴")==1) { start=i; break }
    if (start==0) {
      for (i=1; i<=NR; i++) print lines[i]
      print ""; print "## 判定履歴"; print ""; print entry
      exit
    }
    end=NR
    for (i=start+1; i<=NR; i++) if (index(lines[i],"## ")==1) { end=i-1; break }
    np=0; nh=0
    for (i=start+1; i<=end; i++) {
      if (index(lines[i],"- ")==1) hist[++nh]=lines[i]; else pre[++np]=lines[i]
    }
    hist[++nh]=entry
    first = (nh>keep) ? nh-keep+1 : 1
    for (i=1; i<=start; i++) print lines[i]
    for (i=1; i<=np; i++) print pre[i]
    for (i=first; i<=nh; i++) print hist[i]
    for (i=end+1; i<=NR; i++) print lines[i]
  }' "$GOAL" >"$_hist_tmp" && mv "$_hist_tmp" "$GOAL" || {
  rm -f "$_hist_tmp" 2>/dev/null
  warn "判定履歴の追記に失敗 (round=$round)"
}

if [ "$met" = "true" ]; then
  update_field status done
  printf '{"systemMessage":"goal-gate: 完了条件をすべて満たしたと判定しました (ラウンド %s/%s)。goal.md を status: done に更新しました。"}\n' "$round" "$max_rounds"
  exit 0
fi

{
  printf 'ゴール判定: 未達 (ラウンド %s/%s)。\n' "$round" "$max_rounds"
  if [ -n "$unmet" ]; then
    printf '未達条件: %s\n' "$unmet"
  elif [ -n "$violations" ]; then
    printf '未達条件: なし(完了条件は満たしているが制約に違反している)\n'
  else
    printf '未達条件: (未特定)\n'
  fi
  [ -n "$violations" ] && printf '制約違反: %s\n' "$violations"
  printf '理由: %s\n' "$reason"
  printf '完了条件を満たすまで作業を続けること。判定器は会話に出力された内容しか読めないため、満たしたと考える場合は各条件に併記された検証コマンドを実際に実行し、その出力を提示すること。\n'
} >&2
exit 2
