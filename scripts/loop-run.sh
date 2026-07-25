#!/bin/bash
# loop-run.sh — 無人で 1 イテレーションを回すエントリポイント。
# 使い方: loop-run.sh          (cron / launchd から呼ぶ。登録そのものは人が行う = ゲート)
#   exit 0 = 正常に 1 回まわした / exit 1 = 予算超過・paused・実行失敗
#
# なぜ `claude -p` を新しいプロセスで起動するのか:
#   1. プラグインはキャッシュへの実コピーで、hooks はセッション開始時に固定される。
#      同じセッション内でループの改修をドッグフーディングすることは原理的にできない
#   2. cloud の Routines はローカルのリポジトリにも MCP にも触れない。
#      ローカルリポジトリを触るループの無人化は cron + claude -p が現実的な形になる
#
# 予算はドルで持つ。`--max-budget-usd` に「その日の残り」を渡し、実費 (total_cost_usd) を
# 台帳に記録する。回数と時間による近似は対話セッション用のフォールバックとして残す。
set -u

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1

command -v claude >/dev/null 2>&1 || {
  echo "loop-run: claude CLI が見つかりません" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "loop-run: jq が見つかりません" >&2
  exit 1
}

# --- 予算ゲート ---
# **--check を使う(記録しない)**。この後に起動する /crystal:loop next の手順 1 が
# 同じゲートを記録付きで呼ぶため、ここで記録すると 1 イテレーションで実行回数を
# 2 回消費し、日次の上限が黙って半分になる(実測で踏んだ)。
guard=$("$ROOT/scripts/loop-guard.sh" --check) || {
  echo "loop-run: $(printf '%s' "$guard" | jq -r '.reason // "実行できません"')" >&2
  exit 1
}

# --- 暴走の歯止め ---
# ターン数で止める。**金額では止めない**: サブスクリプション(Max 等)では total_cost_usd は
# トークン数から計算した参考値にすぎず、追加課金も発生しないので、金額を上限にしても
# 意味のある歯止めにならない。ターン数なら課金形態に依存しない。
# 正常なイテレーションでは発火しない値にすること(発火したら中断として扱われる)。
turns=$(printf '%s' "$guard" | jq -r '.max_turns_per_run // empty')
extra_args=""
case "$turns" in
'' | null) ;;
*) extra_args="--max-turns $turns" ;;
esac

# 実費の上限が設定されている場合(API キー運用・CI)だけ、CLI 側にも渡す
budget=$(printf '%s' "$guard" | jq -r '.cost_remaining_usd // empty')
case "$budget" in
'' | null) ;;
*) extra_args="$extra_args --max-budget-usd $budget" ;;
esac

LEDGER=".claude/loop/run-log.jsonl"
JUDGE_LOG=".claude/loop/judge-log.jsonl"
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

# 実行前の判定回数を控える。内側ループが本当に回ったかを後で照合する。
# リダイレクト失敗のメッセージは `<file 2>/dev/null` では消えない(順序の都合)ので存在を先に見る
judge_before=0
[ -f "$JUDGE_LOG" ] && judge_before=$(wc -l <"$JUDGE_LOG" | tr -d ' ')
case "$judge_before" in '' | *[!0-9]*) judge_before=0 ;; esac

# 実行前にキュー先頭の id と、台帳の最新の結果行を控える。
# 中断されたイテレーションが台帳に何も残さないと、次の周回が「何が起きたか」を読めない。
head_id=$("$ROOT/scripts/loop-next.sh" 2>/dev/null | jq -r '.id // empty' 2>/dev/null)
result_before=$("$ROOT/scripts/loop-log.sh" --recent 1 2>/dev/null | jq -r '.ts // empty' 2>/dev/null)

# 台帳に新しい結果行が積まれたか(= エージェントが自分で記録したか)
recorded_result() {
  local now
  now=$("$ROOT/scripts/loop-log.sh" --recent 1 2>/dev/null | jq -r '.ts // empty' 2>/dev/null)
  [ -n "$now" ] && [ "$now" != "$result_before" ]
}

# CRYSTAL_UNATTENDED=1 は 2 つの意味を持つ:
#   pre-bash-guard がゲート該当コマンド (PR 作成・マージ・依存追加) を deny する
#   /crystal:loop next がキュー枯渇時に signal を勝手に昇格させない
#
# CRYSTAL_LOOP_CMD で中身を差し替えられる(eval が課金せずにこのスクリプト自身を検証する)。
if [ -n "${CRYSTAL_LOOP_CMD:-}" ]; then
  # スタブにも同じ引数を渡す。渡さないと「どの上限で起動したか」を eval で確かめられない
  # shellcheck disable=SC2086
  CRYSTAL_UNATTENDED=1 $CRYSTAL_LOOP_CMD $extra_args >"$out" 2>/dev/null
  status=$?
else
  # shellcheck disable=SC2086
  CRYSTAL_UNATTENDED=1 claude -p "/crystal:loop next" \
    --output-format json --no-session-persistence $extra_args \
    >"$out" 2>/dev/null
  status=$?
fi

cost=$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null)
case "$cost" in '' | null) cost=0 ;; esac
subtype=$(jq -r '.subtype // "unknown"' "$out" 2>/dev/null)

# 実費は必ず記録する。失敗した実行のコストも予算から引かないと、
# 失敗を繰り返すループが無限に課金できてしまう。
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
jq -nc --arg ts "$(date -Iseconds)" --argjson c "$cost" --arg s "$subtype" \
  '{ts: $ts, event: "cost", cost_usd: $c, subtype: $s}' >>"$LEDGER" 2>/dev/null

if [ "$status" -ne 0 ] || [ "$subtype" != "success" ]; then
  # 途中で打ち切られたイテレーションを台帳に残す。予算上限やクラッシュで中断されると
  # エージェントは手順 7 まで到達できず、台帳には cost 行しか残らない。
  # それだと次の周回が手順 0 で「前回 Q-7 が途中で切れた」ことを読めない。
  if [ -n "$head_id" ] && ! recorded_result; then
    "$ROOT/scripts/loop-log.sh" "$head_id" failed 0 \
      "実行が中断 (subtype=$subtype, cost=\$$cost)。作業が中途の可能性があるので差分を確認すること" \
      >/dev/null 2>&1
  fi
  echo "loop-run: 実行が正常終了しませんでした (subtype=$subtype, cost=\$$cost)" >&2
  exit 1
fi

# --- 内側ループが本当に回ったかを照合する ---
# 「done と報告されたが判定器が一度も動いていない」= goal-gate を通らずに自己採点しただけ。
# エージェントが goal.md を作らなかった、実装後に作った、自分で done に書き換えた場合に起きる。
# 手順書で禁じてはいるが指示は強制ではないので、無人実行では機械的に検出する
# (対話セッションでは人がその場で気づけるため、ここでは扱わない)。
judge_after=$(wc -l <"$JUDGE_LOG" 2>/dev/null | tr -d ' ')
case "$judge_after" in '' | *[!0-9]*) judge_after=0 ;; esac

last=$("$ROOT/scripts/loop-log.sh" --recent 1 2>/dev/null)
last_result=$(printf '%s' "$last" | jq -r '.result // empty' 2>/dev/null)
last_id=$(printf '%s' "$last" | jq -r '.item_id // empty' 2>/dev/null)

if [ "$last_result" = "done" ] && [ "$judge_after" -le "$judge_before" ]; then
  msg="内側ループが動いていない: done と記録されたが判定器が一度も判定していない。自己採点のみ"
  [ -n "$last_id" ] && "$ROOT/scripts/loop-log.sh" "$last_id" failed 0 "$msg" >/dev/null 2>&1
  echo "loop-run: $msg (cost=\$$cost)" >&2
  exit 1
fi

echo "loop-run: 1 イテレーション完了 (cost=\$$cost, 判定 $((judge_after - judge_before)) 回)"
