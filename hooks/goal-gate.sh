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

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

GOAL=".claude/goal.md"
[ -f "$GOAL" ] || exit 0

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/goal-gate.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null

warn() {
  printf '{"ts":"%s","level":"warn","msg":"%s"}\n' "$(date -Iseconds)" "$1" >>"$LOG" 2>/dev/null
}

# frontmatter の値を取得(行末コメントと前後空白を除去)
get_field() {
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" {
      sub("^"k": *", ""); sub(" *#.*$", ""); gsub(/^ +| +$/, ""); print; exit
    }' "$GOAL"
}

# frontmatter の値を書き換え
update_field() {
  awk -v k="$1" -v v="$2" '
    /^---$/ { fm++ }
    fm==1 && $0 ~ "^"k":" { print k": "v; next }
    { print }' "$GOAL" >"$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
}

status=$(get_field status)
[ "$status" = "active" ] || exit 0

round=$(get_field round)
max_rounds=$(get_field max_rounds)
case "$round" in '' | *[!0-9]*) round=0 ;; esac
case "$max_rounds" in '' | *[!0-9]*) max_rounds=5 ;; esac

# --- 判定前にラウンドを進めて永続化(判定がクラッシュしてもカウントを失わない) ---
round=$((round + 1))
update_field round "$round"

if [ "$round" -gt "$max_rounds" ]; then
  update_field status stalled
  printf '{"systemMessage":"goal-gate: ラウンド上限 (%s) に達したため自動判定を停止しました (status: stalled)。/crystal:goal status で確認してください。"}\n' "$max_rounds"
  exit 0
fi

# --- 判定材料の収集 ---
command -v claude >/dev/null 2>&1 || {
  warn "claude CLI が見つからないため判定をスキップ"
  exit 0
}

transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

context=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  context=$(tail -n 300 "$transcript_path" |
    jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null |
    tail -c 6000)
fi
gitinfo=$(git status --short 2>/dev/null | head -n 30)
conditions=$(awk '/^## 完了条件/{f=1;next} /^## /{f=0} f' "$GOAL")

prompt="あなたはゴール達成の判定器です。以下の完了条件・直近の作業ログ・git status を読み、完了条件がすべて満たされたかを判定してください。
出力は次の JSON のみ。説明文・コードフェンスは一切付けないこと:
{\"met\": true|false, \"unmet\": [\"未達の条件ID\"], \"reason\": \"簡潔な理由\"}
判定できない条件・情報が足りない条件は未達として扱うこと。

## 完了条件
${conditions}

## 直近の作業ログ (assistant 出力の末尾)
${context}

## git status --short
${gitinfo}"

# --- Haiku による判定 (再帰防止は disableAllHooks + env ガードの二重化) ---
result=$(printf '%s' "$prompt" | CRYSTAL_GOAL_JUDGE=1 timeout 120 \
  claude -p --model claude-haiku-4-5-20251001 \
  --settings '{"disableAllHooks": true}' 2>>"$LOG") || {
  warn "judge 実行失敗 (round=$round)"
  exit 0
}

json=$result
if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  json=$(printf '%s' "$result" | sed -n '/{/,/}/p')
fi
met=$(printf '%s' "$json" | jq -r '.met' 2>/dev/null)
if [ "$met" != "true" ] && [ "$met" != "false" ]; then
  warn "judge 出力のパースに失敗 (round=$round)"
  exit 0
fi

unmet=$(printf '%s' "$json" | jq -r '(.unmet // []) | join(", ")' 2>/dev/null)
reason=$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null)

# --- 判定履歴を記録 (/learn の素材) ---
printf '%s' "$json" | jq -c --arg ts "$(date -Iseconds)" --arg sid "$session_id" --argjson r "$round" \
  '{ts:$ts, session_id:$sid, round:$r, met:.met, unmet:(.unmet // []), reason:(.reason // "")}' \
  >>"$LOG" 2>/dev/null

if [ "$met" = "true" ]; then
  update_field status done
  printf '{"systemMessage":"goal-gate: 完了条件をすべて満たしたと判定しました (ラウンド %s/%s)。goal.md を status: done に更新しました。"}\n' "$round" "$max_rounds"
  exit 0
fi

printf 'ゴール判定: 未達 (ラウンド %s/%s)。\n未達条件: %s\n理由: %s\n完了条件を満たすまで作業を続けること。満たしたと考える場合は、実際のコマンド出力など検証可能な根拠を提示すること。\n' \
  "$round" "$max_rounds" "$unmet" "$reason" >&2
exit 2
