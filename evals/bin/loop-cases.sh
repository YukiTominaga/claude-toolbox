#!/bin/bash
# loop-cases.sh — evals/cases/loop-*.md から呼ばれるシナリオ実行ヘルパー。
# 使い方: loop-cases.sh <シナリオ名>
# 一時ディレクトリに最小のプロジェクトを作り、期待どおりかを検証する。
# 成功時は "OK: ..." を出して exit 0、失敗時は "NG: ..." を出して exit 1。
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCENARIO="${1:-}"

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

ok() {
  echo "OK: $1"
  exit 0
}
ng() {
  echo "NG: $1"
  exit 1
}

next() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-next.sh" "$@"; }
guard() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-guard.sh" "$@"; }
loglog() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-log.sh" "$@"; }
goalgate() {
  printf '{"transcript_path":"","session_id":"eval"}' |
    CLAUDE_PROJECT_DIR="$WORK" bash "$ROOT/hooks/goal-gate.sh"
}

write_queue() {
  mkdir -p "$WORK/docs"
  cat >"$WORK/docs/backlog.md"
}

write_loop() { cat >"$WORK/LOOP.md"; }

# .claude/goal.md を作る。$1=max_no_progress $2=started_epoch $3=max_minutes
write_goal() {
  mkdir -p "$WORK/.claude"
  cat >"$WORK/.claude/goal.md" <<EOF
---
status: active
round: 0
max_rounds: 5
no_progress: 0
max_no_progress: $1
last_sig:
started_epoch: $2
max_minutes: $3
created: 2026-01-01
spec:
---
# ゴール: eval

## 完了条件

- [ ] DC-1: 何か
EOF
}

init_git() {
  git -C "$WORK" init -q .
  git -C "$WORK" config user.email eval@example.com
  git -C "$WORK" config user.name eval
  echo seed >"$WORK/seed.txt"
  git -C "$WORK" add seed.txt
  git -C "$WORK" commit -qm seed
}

goal_field() { # $1=key
  awk -v k="$1" '/^---$/{fm++; next} fm==1 && $0 ~ "^"k":" { sub("^"k": *",""); print; exit }' \
    "$WORK/.claude/goal.md"
}

case "$SCENARIO" in

# discover: 完了済みを飛ばして先頭の未着手 1 件を返す
next-first)
  write_queue <<'EOF'
- [x] Q-0: 済んだやつ
- [ ] Q-1: 次にやるやつ  <!-- spec: docs/spec/a.md, priority: high -->
- [ ] Q-2: その次
EOF
  out=$(next) || ng "exit $? (0 を期待)"
  [ "$(printf '%s' "$out" | jq -r .id)" = "Q-1" ] || ng "id が Q-1 でない: $out"
  [ "$(printf '%s' "$out" | jq -r .spec)" = "docs/spec/a.md" ] || ng "spec を取り出せていない: $out"
  ok "先頭の未着手項目とメタデータを取り出せた"
  ;;

# discover: キューが枯れたら exit 3(ループを止めてよい合図)
next-dry)
  write_queue <<'EOF'
- [x] Q-1: 済
EOF
  next >/dev/null 2>&1
  [ "$?" -eq 3 ] || ng "枯渇時の exit が 3 でない"
  rm -f "$WORK/docs/backlog.md"
  next >/dev/null 2>&1
  [ "$?" -eq 3 ] || ng "キューファイル不在時の exit が 3 でない"
  ok "キュー枯渇・不在ともに exit 3"
  ;;

# 予算ゲート: LOOP.md が無ければ素通し(fail-open)
guard-open)
  guard >/dev/null || ng "LOOP.md 不在で素通ししていない"
  ok "LOOP.md 不在は fail-open"
  ;;

# 予算ゲート: 当日の実行回数が上限に達したら止める
guard-budget)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 1
max_minutes_per_run: 30
---
EOF
  guard >/dev/null || ng "1 回目の実行が許可されていない"
  loglog Q-1 done 1 "eval" >/dev/null || ng "台帳への追記に失敗"
  guard >/dev/null 2>&1 && ng "上限到達後も実行が許可された"
  ok "上限到達で実行を止めた"
  ;;

# 予算ゲート: paused の間は動かない
guard-paused)
  write_loop <<'EOF'
---
status: paused
max_runs_per_day: 8
---
EOF
  guard >/dev/null 2>&1 && ng "paused でも実行が許可された"
  ok "paused では実行しない"
  ;;

# 台帳: 想定外の result を受け付けない
log-reject)
  loglog Q-1 wrong >/dev/null 2>&1 && ng "不正な result を受け付けた"
  [ -f "$WORK/.claude/loop/run-log.jsonl" ] && ng "不正な result で台帳に書き込まれた"
  loglog Q-1 done 2 "メモ" >/dev/null || ng "正常な追記に失敗"
  [ "$(wc -l <"$WORK/.claude/loop/run-log.jsonl")" -eq 1 ] || ng "台帳の行数が 1 でない"
  jq -e . "$WORK/.claude/loop/run-log.jsonl" >/dev/null || ng "台帳が JSON として不正"
  ok "不正な result を弾き、正常時は 1 行追記する"
  ;;

# 停止条件 3: 経過時間が max_minutes を超えたら stalled
goal-budget)
  init_git
  write_goal 2 "$(($(date +%s) - 7200))" 60
  goalgate >/dev/null 2>&1 || ng "予算超過時の exit が 0 でない"
  [ "$(goal_field status)" = "stalled" ] || ng "status が stalled になっていない"
  ok "経過時間の超過で stalled になる"
  ;;

# 停止条件 4: 差分に変化がないラウンドが続いたら stalled
goal-no-progress)
  init_git
  write_goal 1 "$(date +%s)" 60
  sig=$(cd "$WORK" && { git diff HEAD; git status --porcelain; } 2>/dev/null | cksum | tr -d ' ')
  sed -i.bak "s/^last_sig:.*/last_sig: $sig/" "$WORK/.claude/goal.md" && rm -f "$WORK/.claude/goal.md.bak"
  goalgate >/dev/null 2>&1
  [ "$?" -eq 0 ] || ng "無進捗の上限到達時の exit が 0 でない"
  [ "$(goal_field status)" = "stalled" ] || ng "status が stalled になっていない"
  ok "無進捗の継続で stalled になる"
  ;;

# 旧形式(新フィールドを持たない)の goal.md でも動き、フィールドが補われる
# ラウンド上限で必ず止まる形にして、判定器 (claude CLI) を呼ばずに完結させる
goal-migrate)
  init_git
  mkdir -p "$WORK/.claude"
  printf -- '---\nstatus: active\nround: 5\nmax_rounds: 5\n---\n# ゴール\n\n## 完了条件\n\n- [ ] DC-1: x\n' \
    >"$WORK/.claude/goal.md"
  goalgate >/dev/null 2>&1 || ng "ラウンド上限到達時の exit が 0 でない"
  for k in no_progress max_no_progress last_sig started_epoch max_minutes; do
    grep -qE "^$k:" "$WORK/.claude/goal.md" || ng "$k が補われていない"
  done
  [ "$(goal_field round)" = "6" ] || ng "round が進んでいない"
  [ "$(goal_field status)" = "stalled" ] || ng "status が stalled になっていない"
  ok "旧形式の goal.md に停止条件のフィールドを補い、上限で止まる"
  ;;

*)
  echo "不明なシナリオ: ${SCENARIO:-(なし)}" >&2
  exit 2
  ;;
esac
