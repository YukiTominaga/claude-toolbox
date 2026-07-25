#!/bin/bash
# auto-commit.sh — 作業途中の変更を自動でコミットし、未コミットの取りこぼしを防ぐ。
# Stop hook。全リポジトリで動くが、以下は無条件でスキップする:
#   main / master / detached HEAD (rules/git-workflow.md の「main に直接コミットしない」)
#   rebase / merge / cherry-pick / revert / bisect の途中
#   git 管理下でない場合、変更が無い場合
# 機密の可能性があるパスが対象に含まれるときはコミットせず systemMessage で知らせる。
#
# stop-gate.sh と同様 stop_hook_active では素通しする: 差し戻しの往復ごとに
# コミットを刻まず、ターンが素直に終わったときだけ 1 コミットにする。
#
# 注意: このフックは git add -A 相当で未追跡ファイルも取り込む。これは
# rules/git-workflow.md の一括 add 禁止に対する明示的な例外であり、
# 機密パスの検出で中止することを引き換えの安全策としている。
set -u

# --- 再帰防止: 判定器や自分自身が起動した claude から呼ばれた場合は素通し ---
if [ "${CRYSTAL_GOAL_JUDGE:-}" = "1" ] || [ "${CRYSTAL_AUTOCOMMIT:-}" = "1" ]; then
  exit 0
fi

input=$(cat)

if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

branch=$(git branch --show-current 2>/dev/null)
case "$branch" in '' | main | master) exit 0 ;; esac

gitdir=$(git rev-parse --git-dir 2>/dev/null) || exit 0
for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
  [ -e "$gitdir/$marker" ] && exit 0
done

untracked=$(git ls-files --others --exclude-standard 2>/dev/null)
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$untracked" ]; then
  exit 0
fi

# --- 機密の可能性があるパスが含まれていたら中止して知らせる ---
candidates=$( {
  git diff --name-only
  git diff --cached --name-only
  printf '%s\n' "$untracked"
} 2>/dev/null | grep -v '^$' | sort -u)

secret=$(printf '%s\n' "$candidates" | grep -iE \
  '(^|/)(\.env($|\.)|\.npmrc$|\.netrc$|credentials|secrets?\.|id_rsa|id_ed25519|\.ssh/|\.aws/)|\.(pem|key|p12|pfx|keystore|jks)$' |
  head -n 3)

if [ -n "$secret" ]; then
  jq -nc --arg p "$(printf '%s' "$secret" | tr '\n' ' ')" \
    '{systemMessage: ("auto-commit: 機密の可能性があるパスが含まれるため自動コミットを中止しました (" + $p + ")。.gitignore に追加するか、内容を確認して手動でコミットしてください。")}'
  exit 0
fi

git add -A -- . >/dev/null 2>&1 || exit 0
if git diff --cached --quiet 2>/dev/null; then
  exit 0
fi

# --- コミットメッセージ: Haiku で差分から生成し、失敗したら定型にフォールバック ---
msg=""
if command -v claude >/dev/null 2>&1; then
  prompt="以下の差分に対するコミットメッセージを1行だけ出力してください。
Conventional Commits 形式 (feat: / fix: / docs: / chore: / refactor: / test:)、日本語、72文字以内。
説明・コードフェンス・引用符は一切付けないこと。

## 変更ファイル
$(git diff --cached --stat | tail -n 20)

## 差分 (先頭のみ)
$(git diff --cached | head -c 4000)"

  msg=$(printf '%s' "$prompt" | CRYSTAL_AUTOCOMMIT=1 timeout 60 \
    claude -p --model claude-haiku-4-5-20251001 \
    --settings '{"disableAllHooks": true}' 2>/dev/null |
    head -n 1 | sed -E 's/^[[:space:]]*[`"'"'"']*//; s/[`"'"'"']*[[:space:]]*$//' | cut -c1-120)
fi

if [ -z "$msg" ]; then
  count=$(git diff --cached --name-only | wc -l | tr -d ' ')
  files=$(git diff --cached --name-only | head -n 3 | tr '\n' ' ' | sed 's/ $//')
  msg="chore: 自動コミット (${count} files: ${files})"
fi

if ! git commit -q -m "$msg" 2>/dev/null; then
  echo "auto-commit: コミットに失敗しました (git のユーザー設定を確認してください)" >&2
  exit 0
fi

jq -nc --arg m "$msg" --arg b "$branch" \
  '{systemMessage: ("auto-commit: " + $b + " に自動コミットしました — " + $m)}'
exit 0
