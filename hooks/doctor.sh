#!/bin/bash
# doctor.sh — ハーネス自身の死活確認 (SessionStart)
#
# crystal の hook ゲートは全て fail-open 設計で、依存コマンドが無い環境では
# 検査されずに黙って素通しになる。「壊れても手動 E2E では気づけない」ため、
# 唯一確実に走るセッション開始時に依存を確認し、欠けていれば一度だけ警告を
# コンテキストへ注入する。
#
# 注意: jq の欠落そのものを検出する必要があるため、このスクリプトは jq に
# 依存してはいけない (JSON は固定文字列 + 英数字のみの変数で組む)。
set -u

missing=""
for dep in jq git node; do
  command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
done
[ -n "$missing" ] || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[crystal] 依存コマンドが見つかりません:%s。crystal の hook ゲート (change-gate / verify-gate / stop-gate 等) は fail-open 設計のため、この状態では一切検査されずに素通しになります。ユーザーにこのことを伝え、インストールを案内してください。"}}\n' "$missing"
exit 0
