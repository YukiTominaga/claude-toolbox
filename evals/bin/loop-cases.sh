#!/bin/bash
# loop-cases.sh — loop スクリプト (loop-next / loop-add / loop-guard / loop-log) の
# シナリオ実行ヘルパー。
# 使い方: loop-cases.sh <シナリオ名>
# 一時ディレクトリに最小のプロジェクトを作り、期待どおりかを検証する。
# 成功時は "OK: ..." を出して exit 0、失敗時は "NG: ..." を出して exit 1。
#
# hooks/*.sh とその相互作用のシナリオは hook-cases.sh にある。
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
add() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-add.sh" "$@" 2>/dev/null; }
guard() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-guard.sh" "$@"; }
loglog() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-log.sh" "$@"; }

write_queue() {
  mkdir -p "$WORK/docs"
  cat >"$WORK/docs/backlog.md"
}

write_loop() { cat >"$WORK/LOOP.md"; }

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

# 追記: 採番が既存の Q-<n> の最大値+1 になり、書式が loop-next.sh でパースできる
add-numbering)
  add "キューが無いとき" >/dev/null 2>&1
  [ "$?" -eq 3 ] || ng "キューファイル不在時の exit が 3 でない"

  write_queue <<'EOF'
# バックログ
EOF
  [ "$(add "最初のタスク")" = "Q-1" ] || ng "空のキューで Q-1 にならない"
  [ "$(add "2件目" "docs/spec/foo.md")" = "Q-2" ] || ng "連番が Q-2 にならない"

  # GH-<n> は Issue 番号なので採番に影響してはいけない
  printf -- '- [x] Q-7: 済んだやつ\n- [ ] GH-42: issue 由来\n' >>"$WORK/docs/backlog.md"
  [ "$(add "続き" "" high)" = "Q-8" ] || ng "GH- を除いた最大値+1 になっていない"

  grep -qE '^- \[ \] Q-2: 2件目 +<!-- spec: docs/spec/foo\.md -->$' "$WORK/docs/backlog.md" ||
    ng "spec のメタデータが行末コメントに入っていない"
  grep -qE '^- \[ \] Q-1: 最初のタスク$' "$WORK/docs/backlog.md" ||
    ng "メタ無指定なのにコメントが付いている"

  add "不正な優先度" "" urgent >/dev/null 2>&1
  [ "$?" -eq 1 ] || ng "不正な priority を受け付けた"

  # 追記した行を discover 側が読めること(書式の後方互換)
  out=$(next) || ng "追記後の backlog を loop-next.sh がパースできない"
  [ "$(printf '%s' "$out" | jq -r .id)" = "Q-1" ] || ng "先頭が Q-1 でない: $out"
  ok "採番・メタ書式・discover との互換が期待どおり"
  ;;

# 予算ゲート: LOOP.md が無ければ素通し(fail-open)
guard-open)
  guard >/dev/null || ng "LOOP.md 不在で素通ししていない"
  ok "LOOP.md 不在は fail-open"
  ;;

# 予算ゲート: ゲート自身が実行を数える(エージェントの自己申告に依存しない)
guard-budget)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 2
max_minutes_per_run: 30
---
EOF
  # loop-log.sh を一度も呼ばない = エージェントが台帳を書き忘れた状況を再現する
  guard >/dev/null || ng "1 回目の実行が許可されていない"
  guard >/dev/null || ng "2 回目の実行が許可されていない"
  guard >/dev/null 2>&1 && ng "上限到達後も実行が許可された (予算が消費されていない)"

  # 結果行は予算の集計対象ではない (start 行だけを数える)
  ledger="$WORK/.claude/loop/run-log.jsonl"
  [ "$(grep -c '"event":"start"' "$ledger")" -eq 2 ] || ng "start 行が 2 行でない"
  loglog Q-1 done 1 "eval" >/dev/null || ng "結果行の追記に失敗"
  [ "$(grep -c '"event":"start"' "$ledger")" -eq 2 ] || ng "結果行が start として数えられている"

  ok "ゲート自身が実行を数え、上限で止める"
  ;;

# 予算ゲート: --check は判定だけ返し、予算を消費しない
guard-check)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 1
max_minutes_per_run: 30
---
EOF
  out=$(guard --check) || ng "--check が拒否した"
  printf '%s' "$out" | jq -e '.recorded == false' >/dev/null || ng "recorded:false が返っていない"
  [ -f "$WORK/.claude/loop/run-log.jsonl" ] && ng "--check なのに台帳に書き込んだ"
  guard >/dev/null || ng "--check の後で実行が許可されない (予算を消費してしまった)"
  ok "--check は記録せず判定だけ返す"
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

*)
  echo "不明なシナリオ: ${SCENARIO:-(なし)}" >&2
  exit 2
  ;;
esac
