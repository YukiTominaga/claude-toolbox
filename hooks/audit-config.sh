#!/bin/bash
# audit-config.sh — 既存設定の一括監査(手動実行用)
# 「思考過程を出力させる」系の常設指示は reasoning_extraction 分類器に触れて
# フォールバックや拒否を誘発しうるため、洗い出して除去する。
set -u

targets=(
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.claude/skills"
  "$HOME/.claude/agents"
  "$HOME/.claude/settings.json"
  "./CLAUDE.md"
  "./.claude"
)

patterns=(
  "思考過程"
  "思考の過程"
  "推論過程"
  "考えたことを"
  "思考を開示"
  "explain your reasoning"
  "show your reasoning"
  "reveal your thinking"
  "chain of thought"
  "chain-of-thought"
)

args=()
for p in "${patterns[@]}"; do args+=( -e "$p" ); done

found=0
for t in "${targets[@]}"; do
  [ -e "$t" ] || continue
  if grep -rniH "${args[@]}" "$t" 2>/dev/null; then
    found=1
  fi
done

echo ""
if [ "$found" -eq 0 ]; then
  echo "[OK] 問題のある常設指示は見つかりませんでした。"
else
  echo "[要対応] 上記がヒットしました。"
  echo "  - 内部の思考ブロックの開示を求める指示 → 削除する"
  echo "  - 設計判断の説明を求める意図だった場合 → 「判断の根拠を簡潔に示す」に書き換える"
  echo "(「なぜこの設計にしたか説明して」のような通常のリクエストは問題ありません)"
fi
