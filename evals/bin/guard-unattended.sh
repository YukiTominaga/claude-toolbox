#!/bin/bash
# guard-unattended.sh — pre-bash-guard.sh の無人モード判定を検証する。
# 使い方: guard-unattended.sh
#
# 別ファイルに分けている理由: 検証したいコマンド文字列そのものが危険パターンなので、
# Bash ツールの引数に直接書くと **このリポジトリ自身の pre-bash-guard に阻まれる**。
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GUARD="$ROOT/hooks/pre-bash-guard.sh"

ng() {
  echo "NG: $1"
  exit 1
}

# $1=コマンド $2=無人モードか (1|0) → permissionDecision を返す
# 一致しなかった場合 hook は**何も出力しない**ので、jq の // "allow" は効かない。
# 空出力を allow として扱うのは呼び出し側の責任。
decide() {
  local env_val="$2" out
  out=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" |
    CRYSTAL_UNATTENDED="$env_val" node "$GUARD" 2>/dev/null |
    jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  [ -n "$out" ] || out=allow
  printf '%s' "$out"
}

# ゲート該当: 無人では deny、対話では allow (人が承認できるため)
for cmd in \
  'gh pr create --title x' \
  'gh pr merge 12' \
  'git merge feature/x' \
  'npm install lodash' \
  'pip install requests'; do
  [ "$(decide "$cmd" 1)" = "deny" ] || ng "無人モードで許可された: $cmd"
  [ "$(decide "$cmd" 0)" = "allow" ] || ng "対話モードで拒否された: $cmd"
done

# 通常の作業は無人でも通す
for cmd in \
  'npm test' \
  'git push origin feature/x' \
  'npm install --dry-run lodash'; do
  [ "$(decide "$cmd" 1)" = "allow" ] || ng "無人モードで通常の作業を拒否した: $cmd"
done

# 元からの破壊的コマンドは無人・対話のどちらでも deny のまま
danger="git push --force origin ma""in"
[ "$(decide "$danger" 1)" = "deny" ] || ng "無人モードで force push が通った"
[ "$(decide "$danger" 0)" = "deny" ] || ng "対話モードで force push が通った"

echo "OK: 無人モードでのみゲート該当コマンドを deny する"
