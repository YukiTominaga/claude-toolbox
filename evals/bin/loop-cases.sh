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
signal() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/signal-add.sh" "$@" 2>/dev/null; }
run() { CLAUDE_PROJECT_DIR="$WORK" CRYSTAL_LOOP_CMD="$WORK/bin/loopcmd" "$ROOT/scripts/loop-run.sh"; }

# 無人ループの中身 (claude -p) を差し替えるスタブ。
# $1 = judged    判定器を通して正常終了する
#      unjudged  done と記録するが判定器を通さない (自己採点だけ)
#      aborted   予算上限などで打ち切られる (記帳まで到達しない)
stub_loop_cmd() {
  mkdir -p "$WORK/bin" "$WORK/.claude/loop"
  cat >"$WORK/bin/loopcmd" <<EOF
#!/bin/bash
# どの上限で起動されたかを記録する
echo "\$*" >"$WORK/loopcmd-args"
# エージェントが 1 イテレーションを終えた状態を作る
CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-guard.sh" >/dev/null 2>&1
if [ "$1" = "aborted" ]; then
  printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":3.31}'
  exit 0
fi
CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-log.sh" Q-1 done 1 "スタブ" >/dev/null 2>&1
if [ "$1" = "judged" ]; then
  echo '{"round":1,"met":true}' >>"$WORK/.claude/loop/judge-log.jsonl"
fi
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":1.25}'
EOF
  chmod +x "$WORK/bin/loopcmd"
}

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

# 予算ゲート: 実費の上限。無人実行が積んだ cost 行を合計して判定する
guard-cost)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 99
max_minutes_per_run: 30
max_cost_usd_per_day: 5.0
---
EOF
  out=$(guard --check) || ng "上限未達なのに拒否した"
  printf '%s' "$out" | jq -e '.cost_today_usd == 0' >/dev/null || ng "cost_today_usd が 0 でない"
  printf '%s' "$out" | jq -e '.cost_remaining_usd == 5' >/dev/null || ng "残り予算が返っていない"
  printf '%s' "$out" | jq -e '.max_turns_per_run == 300' >/dev/null || ng "ターン上限の既定が 300 でない"

  mkdir -p "$WORK/.claude/loop"
  ts=$(date -Iseconds)
  printf '{"ts":"%s","event":"cost","cost_usd":3.2}\n{"ts":"%s","event":"cost","cost_usd":1.0}\n' \
    "$ts" "$ts" >>"$WORK/.claude/loop/run-log.jsonl"
  out=$(guard --check) || ng "4.2/5.0 で拒否した"
  printf '%s' "$out" | jq -e '.cost_today_usd == 4.2' >/dev/null || ng "合計が 4.2 でない"
  printf '%s' "$out" | jq -e '(.cost_remaining_usd - 0.8) | fabs < 0.001' >/dev/null ||
    ng "残りが 0.8 でない"

  printf '{"ts":"%s","event":"cost","cost_usd":1.0}\n' "$ts" >>"$WORK/.claude/loop/run-log.jsonl"
  guard --check >/dev/null 2>&1 && ng "上限を超えても実行が許可された"

  # 昨日のコストは今日の予算を食わない
  printf '{"ts":"2020-01-01T00:00:00+09:00","event":"cost","cost_usd":99}\n' \
    >>"$WORK/.claude/loop/run-log.jsonl"
  out=$(guard --check 2>/dev/null)
  printf '%s' "$out" | jq -e '.cost_today_usd == 5.2' >/dev/null || ng "他の日のコストを合計した"

  # 上限が未設定なら実費では判定しない(対話セッションの構成)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 99
max_minutes_per_run: 30
---
EOF
  out=$(guard --check) || ng "上限未設定なのに拒否した"
  printf '%s' "$out" | jq -e 'has("cost_remaining_usd")' >/dev/null && ng "未設定なのに残り予算を返した"
  ok "実費の上限を台帳の合計で判定する"
  ;;

# 無人実行: 判定器を通った 1 イテレーション。実費を記録し、予算は 1 回だけ消費する
run-normal)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 8
max_minutes_per_run: 30
max_turns_per_run: 123
---
EOF
  stub_loop_cmd judged
  out=$(run) || ng "正常な 1 イテレーションで exit が 0 でない: $out"
  printf '%s' "$out" | grep -q '判定 1 回' || ng "判定回数が報告されていない: $out"

  # 暴走の歯止めはターン数。**金額では止めない**(サブスクでは追加課金が無く意味を持たない)
  args=$(cat "$WORK/loopcmd-args")
  printf '%s' "$args" | grep -q -- '--max-turns 123' || ng "ターン上限が渡っていない: $args"
  printf '%s' "$args" | grep -q -- '--max-budget-usd' &&
    ng "実費の上限が未設定なのに金額で止めようとしている: $args"

  ledger="$WORK/.claude/loop/run-log.jsonl"
  [ "$(grep -c '"event":"start"' "$ledger")" -eq 1 ] ||
    ng "1 イテレーションで予算を $(grep -c '"event":"start"' "$ledger") 回消費した (ゲートの二重通過)"
  # 実費は止めるためではなく、1 イテレーションの重さを測るために記録し続ける
  [ "$(grep -c '"event":"cost"' "$ledger")" -eq 1 ] || ng "実費が記録されていない"
  grep '"event":"cost"' "$ledger" | jq -e '.cost_usd == 1.25' >/dev/null || ng "実費の値が違う"
  ok "ターン数で暴走を止め、実費は記録だけする"
  ;;

# 無人実行: done と報告されたのに判定器が動いていないイテレーションを検出する
run-detects-unjudged)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 8
max_minutes_per_run: 30
---
EOF
  stub_loop_cmd unjudged
  out=$(run 2>&1) && ng "内側ループが素通しされたのに成功として扱った"
  printf '%s' "$out" | grep -q '内側ループが動いていない' || ng "理由が報告されていない: $out"

  # 次のイテレーションが手順 0 で読めるよう、台帳に failed が残る
  last=$(loglog --recent 1)
  [ "$(printf '%s' "$last" | jq -r .result)" = "failed" ] ||
    ng "台帳に failed が残っていない: $last"
  [ "$(printf '%s' "$last" | jq -r .item_id)" = "Q-1" ] || ng "item_id が引き継がれていない"
  ok "判定器を通らなかったイテレーションを検出して failed に落とす"
  ;;

# 無人実行: 途中で打ち切られたイテレーションを台帳に残す
run-records-abort)
  write_loop <<'EOF'
---
status: active
max_runs_per_day: 8
max_minutes_per_run: 30
---
EOF
  write_queue <<'EOF'
# バックログ
- [ ] Q-1: 何かやる
EOF
  stub_loop_cmd aborted
  out=$(run 2>&1) && ng "打ち切られたのに成功として扱った"
  printf '%s' "$out" | grep -q 'error_max_budget_usd' || ng "理由が報告されていない: $out"

  # エージェントは手順 7 まで到達できないので、loop-run.sh が代わりに記録する
  last=$(loglog --recent 1)
  [ -n "$last" ] || ng "台帳に何も残っていない (次の周回が状況を読めない)"
  [ "$(printf '%s' "$last" | jq -r .result)" = "failed" ] || ng "failed で記録されていない: $last"
  [ "$(printf '%s' "$last" | jq -r .item_id)" = "Q-1" ] || ng "キュー先頭の id が記録されていない"
  printf '%s' "$last" | jq -r .notes | grep -q '中断' || ng "中断であることがメモに無い"

  # 実費は打ち切られた分も記録する (しないと失敗を繰り返すループが無限に課金できる)
  grep '"event":"cost"' "$WORK/.claude/loop/run-log.jsonl" | jq -e '.cost_usd == 3.31' >/dev/null ||
    ng "打ち切られた実行のコストが記録されていない"
  ok "打ち切られたイテレーションを台帳に残す"
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

# 台帳: --recent が結果行だけを新しい順に返す(次のイテレーションが読む口)
log-recent)
  [ -z "$(loglog --recent 5)" ] || ng "台帳が無いのに何か出力した"

  guard >/dev/null 2>&1 # start 行を 1 行作る (LOOP.md が無いので fail-open だが台帳は作らない)
  loglog Q-1 done 1 "1件目" >/dev/null
  loglog Q-2 blocked 2 "2件目" >/dev/null
  loglog Q-3 failed 3 "3件目" >/dev/null

  out=$(loglog --recent 2)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ] || ng "件数が 2 でない"
  [ "$(printf '%s\n' "$out" | head -n1 | jq -r .item_id)" = "Q-3" ] || ng "新しい順になっていない"
  [ "$(printf '%s\n' "$out" | tail -n1 | jq -r .item_id)" = "Q-2" ] || ng "2 件目が Q-2 でない"

  # 予算の集計用の行 (start / cost) は混ざらない。
  # 除外リスト方式だと行種を足すたびに読み側が壊れるので、両方を明示的に見る
  printf '{"ts":"2026-01-01T00:00:00+09:00","event":"start"}\n' >>"$WORK/.claude/loop/run-log.jsonl"
  printf '{"ts":"2026-01-01T00:00:00+09:00","event":"cost","cost_usd":1.25}\n' >>"$WORK/.claude/loop/run-log.jsonl"
  loglog --recent 10 | grep -q '"event":"start"' && ng "start 行が混ざっている"
  loglog --recent 10 | grep -q '"event":"cost"' && ng "cost 行が混ざっている"

  [ "$(loglog --recent | wc -l | tr -d ' ')" -eq 3 ] || ng "既定件数が 5 になっていない"
  ok "--recent が結果行だけを新しい順に返す"
  ;;

# signals: 採番が連番になり、frontmatter が揃う
signal-add-numbering)
  signal "最初の気づき" >/dev/null 2>&1
  [ "$?" -eq 3 ] || ng "docs/signals/ が無いときの exit が 3 でない"

  mkdir -p "$WORK/docs/signals"
  [ "$(signal "最初の気づき" "Q-1" "本文")" = "S-1" ] || ng "空のときに S-1 にならない"
  [ "$(signal "2件目" "" "本文")" = "S-2" ] || ng "連番が S-2 にならない"
  [ -f "$WORK/docs/signals/S-2.md" ] || ng "ファイル名が S-<n>.md でない"

  # README.md が採番に混ざってはいけない
  [ "$(signal "3件目")" = "S-3" ] || ng "README.md を数えてしまっている"

  for k in id created source status; do
    grep -qE "^$k:" "$WORK/docs/signals/S-1.md" || ng "frontmatter に $k が無い"
  done
  grep -qE '^status: open$' "$WORK/docs/signals/S-1.md" || ng "初期 status が open でない"
  grep -qE '^# 最初の気づき$' "$WORK/docs/signals/S-1.md" || ng "タイトルが見出しになっていない"

  signal "" >/dev/null 2>&1
  [ "$?" -eq 1 ] || ng "空タイトルを受け付けた"
  ok "signals の採番・書式・エラー処理が期待どおり"
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
