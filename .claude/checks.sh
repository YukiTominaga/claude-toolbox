#!/bin/bash
# .claude/checks.sh — このリポジトリの L1 検証。scripts/project-checks.sh から呼ばれる。
# crystal 自身には npm も pytest も無いため、eval スイートが L1 の実体になる。
# これが無いと、内側ループに L1 を戻した効果を自リポジトリで観測できない。
set -u

# 再帰防止: eval スイートは goal-gate / project-checks を偽の入力で起動する。
# それらが一時ディレクトリではなくこのリポジトリを指してしまった場合に、
# eval スイートが自分自身を呼び続けるのを止める。
if [ "${CRYSTAL_SELF_CHECK:-}" = "1" ]; then
  exit 0
fi

cd "$(dirname "$0")/.." || exit 1
CRYSTAL_SELF_CHECK=1 CLAUDE_PROJECT_DIR="$(pwd)" ./scripts/eval-run.sh
