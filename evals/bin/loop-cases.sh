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
add() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-add.sh" "$@" 2>/dev/null; }
guard() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-guard.sh" "$@"; }
loglog() { CLAUDE_PROJECT_DIR="$WORK" "$ROOT/scripts/loop-log.sh" "$@"; }
# hook は PATH から claude を外して呼ぶ。eval が実際の判定器 (Haiku) を叩くと
# 遅く・課金され・出力が非決定的になるため。停止条件や機密検知などの検証したい層は
# いずれも claude の有無より手前で効くので、これで十分に本番経路を通せる。
goalgate() {
  printf '{"transcript_path":"","session_id":"eval","stop_hook_active":false}' |
    CLAUDE_PROJECT_DIR="$WORK" PATH=/usr/bin:/bin bash "$ROOT/hooks/goal-gate.sh"
}

autocommit() { # $1=stop_hook_active (省略時 false)
  printf '{"stop_hook_active":%s}' "${1:-false}" |
    CLAUDE_PROJECT_DIR="$WORK" PATH=/usr/bin:/bin bash "$ROOT/hooks/auto-commit.sh"
}

commit_count() { git -C "$WORK" rev-list --count HEAD 2>/dev/null || echo 0; }

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
  sig=$(cd "$WORK" && { git rev-parse HEAD; git diff HEAD; git status --porcelain; } 2>/dev/null |
    cksum | tr -d ' ')
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

# hook 相互作用: goal-gate と auto-commit を同じターンで動かしても誤 stall しない
# (単体シナリオだけでは、auto-commit が作業ツリーを空にすることで goal-gate の
#  無進捗検知が前進を停滞と誤判定する不具合を捕まえられなかった)
goal-gate-with-auto-commit)
  init_git
  git -C "$WORK" checkout -q -b feature/loop
  mkdir -p "$WORK/.claude"
  echo ".claude/goal.md" >"$WORK/.gitignore"
  cat >"$WORK/.claude/goal.md" <<EOF
---
status: active
round: 0
max_rounds: 20
no_progress: 0
max_no_progress: 2
last_sig:
started_epoch: $(date +%s)
max_minutes: 600
---
# ゴール: eval

## 完了条件

- [ ] DC-1: x
EOF

  # 1 ターン = エージェントの作業 → (Stop) goal-gate → auto-commit
  # $1 = none        何もしない (完全な停滞)
  #      dirty       変更を残したまま終える (auto-commit がコミットする)
  #      committed   ターン中に自分でコミットまで済ませる ← 誤 stall はここで起きる
  ac_turn() {
    case "$1" in
    dirty) echo "work $2" >>"$WORK/feature.txt" ;;
    committed)
      echo "work $2" >>"$WORK/feature.txt"
      git -C "$WORK" add -A
      git -C "$WORK" commit -qm "feat: work $2"
      ;;
    esac
    goalgate >/dev/null 2>&1
    autocommit >/dev/null 2>&1
  }

  # rules が「feature ブランチでは自由にコミット」なので、ターン中に自分でコミットするのが
  # 通常運転になる。この場合 Stop 時点の作業ツリーは空で、作業ツリーだけを署名にしていると
  # 毎ラウンド同一になり、前進しているのに停滞と誤判定される。
  for i in 1 2 3 4; do ac_turn committed "$i"; done
  [ "$(goal_field status)" = "active" ] ||
    ng "自分でコミットしながら前進しているのに stalled になった (round=$(goal_field round), no_progress=$(goal_field no_progress))"

  # 変更を残して終えるターン (auto-commit 任せ) でも誤判定しないこと
  for i in 5 6; do ac_turn dirty "$i"; done
  [ "$(goal_field status)" = "active" ] || ng "auto-commit 任せの前進で stalled になった"
  [ "$(git -C "$WORK" rev-list --count HEAD)" -ge 6 ] || ng "コミットが積まれていない"

  # 手が止まったら検知できること (検知能力を失っていないことの確認)
  for i in 7 8 9; do ac_turn none "$i"; done
  [ "$(goal_field status)" = "stalled" ] || ng "完全に停滞したのに stalled にならない"

  ok "自分でコミットしても誤 stall せず、停滞したら検知する"
  ;;

# 自動コミット: feature ブランチでは未追跡ファイルごとコミットする
auto-commit-basic)
  init_git
  git -C "$WORK" checkout -q -b feature/x
  before=$(commit_count)
  echo "変更" >>"$WORK/seed.txt"
  mkdir -p "$WORK/docs" && echo "新規" >"$WORK/docs/new.md"
  autocommit >/dev/null || ng "auto-commit の exit が 0 でない"
  [ "$(commit_count)" -eq "$((before + 1))" ] || ng "コミットが 1 つ増えていない"
  [ -z "$(git -C "$WORK" status --porcelain)" ] || ng "作業ツリーに変更が残っている"
  git -C "$WORK" show --stat --oneline HEAD | grep -q 'docs/new.md' || ng "未追跡ファイルが含まれていない"
  git -C "$WORK" log -1 --pretty=%s | grep -qE '^(chore|feat|fix|docs|refactor|test):' ||
    ng "コミットメッセージが Conventional Commits 形式でない"
  ok "feature ブランチで未追跡ごと 1 コミットにまとめた"
  ;;

# 自動コミット: 動いてはいけない場面で動かない
auto-commit-skip)
  init_git
  echo "変更" >>"$WORK/seed.txt"

  # main では動かない (rules/git-workflow.md の「main に直接コミットしない」)
  git -C "$WORK" branch -M main
  before=$(commit_count)
  autocommit >/dev/null
  [ "$(commit_count)" -eq "$before" ] || ng "main でコミットしてしまった"

  # 差し戻しの往復中 (stop_hook_active) は動かない
  git -C "$WORK" checkout -q -b feature/y
  autocommit true >/dev/null
  [ "$(commit_count)" -eq "$before" ] || ng "stop_hook_active でコミットしてしまった"

  # 変更が無ければ何もしない
  git -C "$WORK" add -A && git -C "$WORK" commit -qm manual
  before=$(commit_count)
  autocommit >/dev/null
  [ "$(commit_count)" -eq "$before" ] || ng "変更が無いのにコミットした"

  # マージ途中では動かない (git-dir は必ず絶対パスで解決する。相対パスだと
  # このスクリプトの cwd 側 = 実リポジトリに MERGE_HEAD を作ってしまう)
  echo "変更2" >>"$WORK/seed.txt"
  merge_head="$(git -C "$WORK" rev-parse --absolute-git-dir)/MERGE_HEAD"
  : >"$merge_head"
  autocommit >/dev/null
  rm -f "$merge_head"
  [ "$(commit_count)" -eq "$before" ] || ng "マージ途中にコミットした"

  ok "main / 差し戻し中 / 無変更 / マージ途中では動かない"
  ;;

# 自動コミット: 機密の可能性があるパスは中止して知らせる
auto-commit-secret)
  init_git
  git -C "$WORK" checkout -q -b feature/z
  before=$(commit_count)
  echo "変更" >>"$WORK/seed.txt"
  echo "API_KEY=xxx" >"$WORK/.env"
  out=$(autocommit) || ng "auto-commit の exit が 0 でない"
  [ "$(commit_count)" -eq "$before" ] || ng "機密パスがあるのにコミットした"
  printf '%s' "$out" | jq -e '.systemMessage' >/dev/null 2>&1 || ng "systemMessage で知らせていない"
  printf '%s' "$out" | grep -q '\.env' || ng "検出したパスを示していない"

  # .gitignore に入れれば通常どおりコミットされる
  echo ".env" >>"$WORK/.gitignore"
  autocommit >/dev/null || ng "除外後の exit が 0 でない"
  [ "$(commit_count)" -eq "$((before + 1))" ] || ng "除外後にコミットされていない"
  git -C "$WORK" show --stat --oneline HEAD | grep -q '\.env$' && ng ".env がコミットに含まれている"

  ok "機密パスは中止して知らせ、除外後は通常どおり動く"
  ;;

*)
  echo "不明なシナリオ: ${SCENARIO:-(なし)}" >&2
  exit 2
  ;;
esac
