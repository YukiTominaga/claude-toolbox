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

# --- 予算ゲート。通過した時点でゲート自身が start を記録する ---
guard=$("$ROOT/scripts/loop-guard.sh") || {
  echo "loop-run: $(printf '%s' "$guard" | jq -r '.reason // "実行できません"')" >&2
  exit 1
}

budget=$(printf '%s' "$guard" | jq -r '.cost_remaining_usd // empty')
budget_arg=""
case "$budget" in
'' | null) ;; # 日次のドル上限が未設定なら CLI 側の上限は付けない
*) budget_arg="--max-budget-usd $budget" ;;
esac

LEDGER=".claude/loop/run-log.jsonl"
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

# CRYSTAL_UNATTENDED=1 は 2 つの意味を持つ:
#   pre-bash-guard がゲート該当コマンド (PR 作成・マージ・依存追加) を deny する
#   /crystal:loop next がキュー枯渇時に signal を勝手に昇格させない
# shellcheck disable=SC2086
CRYSTAL_UNATTENDED=1 claude -p "/crystal:loop next" \
  --output-format json --no-session-persistence $budget_arg \
  >"$out" 2>/dev/null
status=$?

cost=$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null)
case "$cost" in '' | null) cost=0 ;; esac
subtype=$(jq -r '.subtype // "unknown"' "$out" 2>/dev/null)

# 実費は必ず記録する。失敗した実行のコストも予算から引かないと、
# 失敗を繰り返すループが無限に課金できてしまう。
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
jq -nc --arg ts "$(date -Iseconds)" --argjson c "$cost" --arg s "$subtype" \
  '{ts: $ts, event: "cost", cost_usd: $c, subtype: $s}' >>"$LEDGER" 2>/dev/null

if [ "$status" -ne 0 ] || [ "$subtype" != "success" ]; then
  echo "loop-run: 実行が正常終了しませんでした (subtype=$subtype, cost=\$$cost)" >&2
  exit 1
fi

echo "loop-run: 1 イテレーション完了 (cost=\$$cost)"
