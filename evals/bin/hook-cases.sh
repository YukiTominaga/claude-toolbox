#!/bin/bash
# hook-cases.sh — hooks/*.sh とその相互作用を検証するシナリオ実行ヘルパー。
# 使い方: hook-cases.sh <シナリオ名>
# 一時ディレクトリに最小のプロジェクトを作り、期待どおりかを検証する。
# 成功時は "OK: ..." を出して exit 0、失敗時は "NG: ..." を出して exit 1。
#
# loop スクリプト (loop-next / loop-add / loop-guard / loop-log) のシナリオは
# loop-cases.sh にある。hook を足したらこちらに書くこと。
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

# hook は PATH を絞って呼ぶ。実際の判定器 (Haiku) を叩くと遅く・課金され・出力が
# 非決定的になるため、claude を PATH から外す。npm も同様にスタブに差し替える
# (実 npm は fnm 配下にあり /usr/bin には無いので、絞れば確実にスタブだけが見える)。
# jq と git は macOS 同梱の /usr/bin のものを使う。
epath() { echo "$WORK/bin:/usr/bin:/bin"; }

goalgate() { # $1=stop_hook_active (省略時 false)
  printf '{"transcript_path":"","session_id":"eval","stop_hook_active":%s}' "${1:-false}" |
    CLAUDE_PROJECT_DIR="$WORK" PATH="$(epath)" bash "$ROOT/hooks/goal-gate.sh"
}

stopgate() { # $1=stop_hook_active (省略時 false)
  printf '{"stop_hook_active":%s}' "${1:-false}" |
    CLAUDE_PROJECT_DIR="$WORK" PATH="$(epath)" bash "$ROOT/hooks/stop-gate.sh"
}

autocommit() { # $1=stop_hook_active (省略時 false)
  printf '{"stop_hook_active":%s}' "${1:-false}" |
    CLAUDE_PROJECT_DIR="$WORK" PATH="$(epath)" bash "$ROOT/hooks/auto-commit.sh"
}

checks() { CLAUDE_PROJECT_DIR="$WORK" PATH="$(epath)" "$ROOT/scripts/project-checks.sh"; }

# --- スタブ ---
# npm の呼び出しを記録し、終了コードを外から切り替えられるようにする。
# 「L1 が実際に走ったか」は calls.log の行数で断定する。
stub_npm() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/npm" <<EOF
#!/bin/bash
echo "npm \$*" >>"$WORK/calls.log"
echo "FAKE FAILURE"
exit "\$(cat "$WORK/npm-exit" 2>/dev/null || echo 0)"
EOF
  chmod +x "$WORK/bin/npm"
  set_npm 0
  : >"$WORK/calls.log"
}

set_npm() { printf '%s' "$1" >"$WORK/npm-exit"; }

# goal-gate の判定器スタブ。CRYSTAL_JUDGE_CMD で差し替えて met/unmet の両経路を踏む。
# $1 = true | false | broken (壊れた出力) | error (is_error を返す)
stub_judge() {
  mkdir -p "$WORK/bin"
  case "$1" in
  broken) payload='これは JSON ではありません' ;;
  error) payload='{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.5}' ;;
  *) payload=$(printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0123,"result":"{\\"met\\":%s,\\"unmet\\":[\\"DC-1\\"],\\"reason\\":\\"スタブ判定\\"}"}' "$1") ;;
  esac
  cat >"$WORK/bin/judge" <<EOF
#!/bin/bash
cat >/dev/null
echo "judge \$*" >>"$WORK/calls.log"
printf '%s' '$payload'
EOF
  chmod +x "$WORK/bin/judge"
}

# auto-commit のメッセージ生成が judge を呼んだかどうかを見分けるためのスタブ
stub_claude() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/claude" <<EOF
#!/bin/bash
cat >/dev/null
echo "claude \$*" >>"$WORK/calls.log"
echo "feat: スタブ生成メッセージ"
EOF
  chmod +x "$WORK/bin/claude"
}

calls_count() { # $1=絞り込みの正規表現 (省略時は全行)
  [ -f "$WORK/calls.log" ] || {
    echo 0
    return
  }
  grep -cE "${1:-.}" "$WORK/calls.log" 2>/dev/null || true
}

reset_calls() { : >"$WORK/calls.log"; }

pkg_json() {
  cat >"$WORK/package.json" <<'EOF'
{"name":"eval-fixture","scripts":{"typecheck":"tsc","lint":"eslint","test":"vitest"}}
EOF
}

commit_count() { git -C "$WORK" rev-list --count HEAD 2>/dev/null || echo 0; }

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

# ---------------------------------------------------------------------------
# project-checks.sh 単体
# ---------------------------------------------------------------------------

# 緑ならすべてのチェックを試したうえで exit 0
checks-green)
  pkg_json
  stub_npm
  checks >/dev/null || ng "緑なのに exit が 0 でない"
  [ "$(calls_count)" -eq 3 ] || ng "typecheck/lint/test の 3 つを試していない ($(calls_count) 回)"
  ok "緑なら 3 つのチェックを実行して exit 0"
  ;;

# 赤なら exit 1 で、失敗したチェック名と出力を返す
checks-red)
  pkg_json
  stub_npm
  set_npm 1
  out=$(checks) && ng "赤なのに exit が 0"
  printf '%s' "$out" | grep -q 'FAKE FAILURE' || ng "コマンドの出力を返していない"
  printf '%s' "$out" | grep -q 'typecheck 失敗' || ng "失敗したチェック名を返していない"
  ok "赤なら exit 1 で失敗内容を返す"
  ;;

# 実行できるチェックが無いプロジェクトを赤にしない
checks-none)
  stub_npm
  checks >/dev/null || ng "チェックが無いのに exit が 0 でない"
  [ "$(calls_count)" -eq 0 ] || ng "チェックが無いのに何か実行した"
  ok "チェックが無ければ何もせず exit 0"
  ;;

# **git の状態を見ないこと**。stop-gate の「変更が無ければスキップ」を
# project-checks.sh に持ち込むと、内側ループ (作業ツリーは常に空) で L1 が全ラウンド消える。
checks-ignores-git)
  init_git
  pkg_json
  stub_npm
  git -C "$WORK" add -A && git -C "$WORK" commit -qm fixture
  [ -z "$(git -C "$WORK" status --porcelain)" ] || ng "前提が崩れている (作業ツリーが clean でない)"
  checks >/dev/null || ng "clean な作業ツリーで exit が 0 でない"
  [ "$(calls_count)" -eq 3 ] || ng "作業ツリーが clean だとチェックを実行しない (git を見てしまっている)"
  ok "作業ツリーが clean でも検証を実行する"
  ;;

# ---------------------------------------------------------------------------
# stop-gate.sh (挙動不変であることの固定)
# ---------------------------------------------------------------------------

# 変更があって赤なら差し戻す
stop-gate-red)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  stopgate 2>/dev/null && ng "赤なのに差し戻していない"
  [ "$(calls_count)" -gt 0 ] || ng "検証を実行していない"
  ok "変更があって赤なら exit 2 で差し戻す"
  ;;

# 変更があって緑なら通す
stop-gate-green)
  init_git
  pkg_json
  stub_npm
  stopgate || ng "緑なのに差し戻した"
  [ "$(calls_count)" -gt 0 ] || ng "検証を実行していない"
  ok "変更があって緑なら通す"
  ;;

# 変更が無ければ検証しない (質問応答セッション等)。
# 自分のカウントファイル (未追跡) を「変更あり」と数えないことも同時に確認する。
stop-gate-clean)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  git -C "$WORK" add -A && git -C "$WORK" commit -qm fixture
  mkdir -p "$WORK/.claude/loop" && echo 2 >"$WORK/.claude/loop/stop-gate-pushback"
  stopgate || ng "変更が無いのに差し戻した"
  [ "$(calls_count)" -eq 0 ] || ng "変更が無いのに検証を実行した (カウントファイルを変更と数えた疑い)"
  ok "変更が無ければ検証しない"
  ;;

# 差し戻しの往復中でも検証する。ここを素通しにすると、goal.md の無いセッションでは
# 一度差し戻された時点で L1 が二度と走らなくなる (これが Q-7 で塞いだ穴)。
stop-gate-active-red)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  stopgate true 2>/dev/null && ng "往復中に赤なのに差し戻していない"
  [ "$(calls_count)" -gt 0 ] || ng "往復中に検証を実行していない"
  ok "往復中でも赤なら差し戻す"
  ;;

# 差し戻しは連鎖内で 3 回まで。4 回目は検証せず素通しし、systemMessage で知らせる。
stop-gate-pushback-limit)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  stopgate 2>/dev/null && ng "1 回目に差し戻していない"
  for i in 2 3; do
    stopgate true 2>/dev/null && ng "$i 回目に差し戻していない"
  done
  before=$(calls_count)
  out=$(stopgate true 2>/dev/null) || ng "上限を超えても差し戻し続けている (無限ループ)"
  [ "$(calls_count)" -eq "$before" ] || ng "上限到達後に検証を実行した"
  printf '%s' "$out" | grep -q '差し戻し上限' || ng "上限到達を systemMessage で知らせていない"
  ok "差し戻しは 3 回まで。4 回目は素通しして知らせる"
  ;;

# stop_hook_active: false (連鎖が切れた合図) でカウントがリセットされる
stop-gate-pushback-reset)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  stopgate 2>/dev/null
  stopgate true 2>/dev/null
  stopgate true 2>/dev/null
  stopgate 2>/dev/null && ng "false のラウンドで差し戻していない"
  [ "$(cat "$WORK/.claude/loop/stop-gate-pushback")" = "1" ] ||
    ng "false でカウントがリセットされていない ($(cat "$WORK/.claude/loop/stop-gate-pushback"))"
  stopgate true 2>/dev/null && ng "リセット後に差し戻せていない"

  # **作業ツリーが clean な false 停止でもリセットされること**。
  # auto-commit が毎ターン作業ツリーを空にする運用では clean な false 停止が常態なので、
  # 変更判定より後ろでリセットしていると、カウントが次の連鎖へ持ち越される。
  # その結果、一度も差し戻していない連鎖の初回停止で L1 を飛ばし、
  # 事実に反する「差し戻し上限」を出す(独立検証が捕まえた欠陥)。
  git -C "$WORK" add -A && git -C "$WORK" commit -qm clean
  [ -z "$(git -C "$WORK" status --porcelain -- . ':(exclude).claude/loop')" ] ||
    ng "前提が崩れている (作業ツリーが clean でない)"
  printf '3\n' >"$WORK/.claude/loop/stop-gate-pushback"
  stopgate >/dev/null 2>&1 || ng "clean な false 停止で差し戻した"
  [ "$(cat "$WORK/.claude/loop/stop-gate-pushback")" = "0" ] ||
    ng "clean な false 停止でリセットされない (次の連鎖に持ち越される)"

  # 持ち越されていないので、次の連鎖では初回から検証される
  echo "work" >>"$WORK/feature.txt"
  reset_calls
  out=$(stopgate true 2>/dev/null) && ng "新しい連鎖の初回で差し戻していない"
  [ "$(calls_count)" -gt 0 ] || ng "新しい連鎖の初回で L1 が走っていない"
  printf '%s' "$out" | grep -q '差し戻し上限' && ng "差し戻していないのに上限メッセージを出した"

  ok "false でカウントがリセットされる (clean なターンでも)"
  ;;

# 緑のラウンドではカウントを減らさない。減らすと赤緑の往復で上限に到達しなくなる
stop-gate-green-keeps-count)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  stopgate 2>/dev/null                        # 1 回目の差し戻し (count=1)
  set_npm 0
  stopgate true >/dev/null 2>&1 || ng "緑なのに差し戻した"
  [ "$(cat "$WORK/.claude/loop/stop-gate-pushback")" = "1" ] ||
    ng "緑のラウンドでカウントが減った ($(cat "$WORK/.claude/loop/stop-gate-pushback"))"

  # 赤緑を往復しても上限に到達する
  for _ in 1 2; do
    set_npm 1
    stopgate true 2>/dev/null
    set_npm 0
    stopgate true >/dev/null 2>&1
  done
  set_npm 1
  out=$(stopgate true 2>/dev/null) || ng "赤緑の往復で上限に到達しない (無限ループ)"
  printf '%s' "$out" | grep -q '差し戻し上限' || ng "上限到達が知らされていない"
  ok "緑のラウンドではカウントを減らさない"
  ;;

# カウントを永続化できない環境では、往復中は素通しする (上限を数えられないため)。
# 初回停止は 1 回で済むので従来どおり検証する。
stop-gate-no-state-dir)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  mkdir -p "$WORK/.claude/loop" && chmod 500 "$WORK/.claude/loop"
  # root で回すと chmod が効かず前提が崩れる。効いていないなら判定せず落とす
  : 2>/dev/null >>"$WORK/.claude/loop/stop-gate-pushback" &&
    ng "前提が崩れている (chmod 500 のディレクトリに書けてしまう)"
  stopgate true || ng "カウントできないのに往復中に差し戻した (無限ループの危険)"
  [ "$(calls_count)" -eq 0 ] || ng "往復中に検証を実行した"
  stopgate 2>/dev/null && ng "初回停止で赤なのに差し戻していない"
  [ "$(calls_count)" -gt 0 ] || ng "初回停止で検証を実行していない"
  chmod 700 "$WORK/.claude/loop"
  ok "カウントできない環境では往復中だけ素通しする"
  ;;

# ---------------------------------------------------------------------------
# goal-gate.sh の L1 ゲート
# ---------------------------------------------------------------------------

# claude CLI が無くても L1 だけは効く。
# claude 不在なら goal-gate は本来 exit 0 (fail-open) にしかならないので、
# exit 2 が返るのは判定器より手前で L1 が赤を出したとき以外にありえない。
# = 挿入位置が `command -v claude` より前であることの証明。
goal-l1-blocks-without-claude)
  init_git
  write_goal 2 "$(date +%s)" 60
  pkg_json
  stub_npm
  set_npm 1
  goalgate 2>/dev/null && ng "赤なのに差し戻していない (判定器より後ろに置かれている疑い)"
  [ "$(calls_count)" -gt 0 ] || ng "検証を実行していない"
  [ "$(goal_field round)" = "1" ] || ng "ラウンドが進んでいない"
  ok "claude 不在でも L1 が赤なら差し戻す"
  ;;

# 差し戻しの往復ラウンド (stop_hook_active=true) でも L1 が走る。
# stop-gate も同じラウンドで検証する (二重実行) が、これは許容した設計上の帰結。
# goal.md を読ませて回避すると「どちらも検証しない」に倒れうるため (docs/spec/Q-7.md)。
goal-l1-runs-in-pushback-round)
  init_git
  write_goal 2 "$(date +%s)" 60
  pkg_json
  stub_npm
  set_npm 1
  goalgate true 2>/dev/null && ng "往復ラウンドで差し戻していない"
  before=$(calls_count)
  [ "$before" -gt 0 ] || ng "往復ラウンドで検証が走っていない (これが直したかった欠陥)"
  stopgate true >/dev/null 2>&1
  [ "$(calls_count)" -gt "$before" ] || ng "往復ラウンドで stop-gate の L1 が走っていない"
  ok "往復ラウンドで goal-gate と stop-gate の両方の L1 が走る"
  ;;

# 緑なら L1 を通過して判定器の層まで到達する (claude 不在なので fail-open で exit 0)
goal-l1-green-passes)
  init_git
  write_goal 2 "$(date +%s)" 60
  pkg_json
  stub_npm
  goalgate >/dev/null 2>&1 || ng "緑なのに差し戻した"
  [ "$(calls_count)" -eq 3 ] || ng "検証を実行していない"
  ok "緑なら判定器の層まで到達する"
  ;;

# **順序の固定**: L1 は停止条件 4 層より後ろにある。
# 前に置くと、赤の間ずっと exit 2 でラウンド上限に到達せず、この hook 自身が無限ループになる。
goal-l1-after-stop-rules)
  init_git
  pkg_json
  stub_npm
  set_npm 1
  mkdir -p "$WORK/.claude"

  # (a) ラウンド上限
  printf -- '---\nstatus: active\nround: 5\nmax_rounds: 5\n---\n# ゴール\n\n## 完了条件\n\n- [ ] DC-1: x\n' \
    >"$WORK/.claude/goal.md"
  reset_calls
  goalgate >/dev/null 2>&1 || ng "(a) ラウンド上限で exit が 0 でない"
  [ "$(goal_field status)" = "stalled" ] || ng "(a) stalled になっていない"
  [ "$(calls_count)" -eq 0 ] || ng "(a) 停止条件より前に L1 を実行した"

  # (b) 壁時計予算
  write_goal 2 "$(($(date +%s) - 7200))" 60
  reset_calls
  goalgate >/dev/null 2>&1 || ng "(b) 予算超過で exit が 0 でない"
  [ "$(goal_field status)" = "stalled" ] || ng "(b) stalled になっていない"
  [ "$(calls_count)" -eq 0 ] || ng "(b) 停止条件より前に L1 を実行した"

  # (c) 無進捗。1 回目で hook 自身に last_sig を打たせ、何も変えずに 2 回目で上限に触れさせる
  write_goal 1 "$(date +%s)" 60
  goalgate >/dev/null 2>&1
  reset_calls
  goalgate >/dev/null 2>&1 || ng "(c) 無進捗の上限で exit が 0 でない"
  [ "$(goal_field status)" = "stalled" ] || ng "(c) stalled になっていない"
  [ "$(calls_count)" -eq 0 ] || ng "(c) 停止条件より前に L1 を実行した"

  ok "L1 は停止条件 4 層より後ろにある"
  ;;

# 赤い L1 でもラウンドは消費され、ループは必ず有限で終わる
goal-l1-round-consumed)
  init_git
  write_goal 2 "$(date +%s)" 60
  pkg_json
  stub_npm
  set_npm 1
  # 毎ラウンド作業ツリーを変える = 無進捗検知ではなくラウンド上限で止まる経路を通す
  for i in 1 2 3 4 5 6 7; do
    echo "work $i" >>"$WORK/feature.txt"
    goalgate >/dev/null 2>&1
    [ "$(goal_field status)" = "stalled" ] && break
  done
  [ "$(goal_field status)" = "stalled" ] || ng "赤いまま回り続けて止まらない (round=$(goal_field round))"
  ok "赤い L1 でもラウンドを消費し、上限で止まる"
  ;;

# ---------------------------------------------------------------------------
# goal-gate.sh の判定器 (L4)
# ---------------------------------------------------------------------------

# 達成と判定されたら status: done になり、コストが履歴に残る
goal-judge-met)
  init_git
  write_goal 2 "$(date +%s)" 60
  stub_npm
  stub_judge true
  export CRYSTAL_JUDGE_CMD="$WORK/bin/judge"
  goalgate >/dev/null 2>&1 || ng "達成時の exit が 0 でない"
  [ "$(goal_field status)" = "done" ] || ng "status が done になっていない"
  [ "$(calls_count '^judge')" -eq 1 ] || ng "判定器が呼ばれていない"
  log="$WORK/.claude/loop/judge-log.jsonl"
  [ -s "$log" ] || ng "判定履歴が書かれていない"
  [ "$(tail -n1 "$log" | jq -r .met)" = "true" ] || ng "履歴の met が true でない"
  [ "$(tail -n1 "$log" | jq -r .cost_usd)" = "0.0123" ] || ng "コストが記録されていない"
  ok "達成判定で done になり、コストも記録される"
  ;;

# 未達なら差し戻し、未達条件が伝わる
goal-judge-unmet)
  init_git
  write_goal 2 "$(date +%s)" 60
  stub_npm
  stub_judge false
  export CRYSTAL_JUDGE_CMD="$WORK/bin/judge"
  out=$(goalgate 2>&1) && ng "未達なのに差し戻していない"
  [ "$(goal_field status)" = "active" ] || ng "未達で status が変わってしまった"
  printf '%s' "$out" | grep -q 'DC-1' || ng "未達条件が伝わっていない"
  printf '%s' "$out" | grep -q 'スタブ判定' || ng "理由が伝わっていない"
  [ "$(tail -n1 "$WORK/.claude/loop/judge-log.jsonl" | jq -r .met)" = "false" ] || ng "履歴の met が false でない"
  ok "未達なら未達条件と理由を添えて差し戻す"
  ;;

# 判定器が壊れた出力やエラーを返したら fail-open (ループを止めない)
goal-judge-broken)
  init_git
  write_goal 2 "$(date +%s)" 60
  stub_npm

  # ラウンド間で作業ツリーを変える。変えないと無進捗層が判定器より手前で差し戻し、
  # 判定器の経路を踏めない。
  # **毎回別のファイルを作ること**: 未追跡ファイルへの追記は git status --porcelain の
  # 出力を変えないので署名も変わらず、「進んでいない」と見なされる
  stub_judge broken
  export CRYSTAL_JUDGE_CMD="$WORK/bin/judge"
  echo w >"$WORK/w1.txt"
  goalgate >/dev/null 2>&1 || ng "壊れた出力で fail-open していない"
  [ "$(goal_field status)" = "active" ] || ng "壊れた出力で status を変えた"

  stub_judge error
  echo w >"$WORK/w2.txt"
  goalgate >/dev/null 2>&1 || ng "エラー応答で fail-open していない"
  [ "$(goal_field status)" = "active" ] || ng "エラー応答で status を変えた"
  grep -q 'judge がエラーを返した' "$WORK/.claude/loop/judge-log.jsonl" || ng "エラーが記録されていない"
  ok "判定器が壊れてもループを止めず、痕跡を残す"
  ;;

# ---------------------------------------------------------------------------
# 合成 (hook 同士の相互作用)
# ---------------------------------------------------------------------------

# 内側ループを通しで回す。1 ターン = stop-gate → goal-gate → auto-commit。
# round1 は stop_hook_active=false、差し戻された 2 ラウンド目以降は true になる。
inner-loop-l1)
  init_git
  git -C "$WORK" checkout -q -b feature/loop
  echo ".claude/goal.md" >"$WORK/.gitignore"
  write_goal 2 "$(date +%s)" 600
  sed -i.bak 's/^max_rounds:.*/max_rounds: 20/' "$WORK/.claude/goal.md" &&
    rm -f "$WORK/.claude/goal.md.bak"
  pkg_json
  stub_npm
  set_npm 1

  turn() { # $1=stop_hook_active
    echo "work $2" >>"$WORK/feature.txt"
    stopgate "$1" >/dev/null 2>&1
    goalgate "$1" >/dev/null 2>&1
    gg=$?
    autocommit "$1" >/dev/null 2>&1
    return $gg
  }

  turn false 1 && ng "round1: 赤なのに差し戻していない"

  # 往復ラウンドでは stop-gate と goal-gate が両方検証するので 2 回分 (6 コマンド) 増える。
  # 二重実行は Q-7 で許容した帰結 (docs/spec/Q-7.md の「含まないもの」)。
  for i in 2 3; do
    before=$(calls_count '^npm')
    turn true "$i" && ng "round$i: 赤なのに差し戻していない (L1 の床が抜けている)"
    [ "$(calls_count '^npm')" -eq "$((before + 6))" ] ||
      ng "round$i: L1 の実行回数が 2 回分でない ($(($(calls_count '^npm') - before)) コマンド)"
  done

  # 緑にすれば通過し、判定器の層まで到達する (claude 不在なので fail-open)
  set_npm 0
  turn true 4 || ng "緑にしたのに差し戻された"

  [ "$(commit_count)" -ge 4 ] || ng "内側ループ中にコミットが積まれていない ($(commit_count) 件)"
  ok "内側ループの全ラウンドで L1 が走り、コミットも積まれる"
  ;;

# 差し戻しの往復中もコミットする。ただしメッセージ生成の judge は呼ばない。
auto-commit-inner-loop)
  init_git
  git -C "$WORK" checkout -q -b feature/loop
  stub_npm
  stub_claude

  # 往復中: コミットはするが claude は呼ばない
  before=$(commit_count)
  echo "work 1" >>"$WORK/feature.txt"
  autocommit true >/dev/null || ng "往復中の exit が 0 でない"
  [ "$(commit_count)" -eq "$((before + 1))" ] ||
    ng "往復中にコミットしていない (無人実行で成果が失われる)"
  [ "$(calls_count '^claude')" -eq 0 ] || ng "往復中に judge を呼んだ (往復ごとに課金される)"
  git -C "$WORK" log -1 --pretty=%s | grep -q '^chore: 自動コミット' ||
    ng "往復中のメッセージが定型フォールバックでない: $(git -C "$WORK" log -1 --pretty=%s)"

  # 素直に終わったターン: judge でメッセージを生成する
  before=$(commit_count)
  echo "work 2" >>"$WORK/feature.txt"
  autocommit false >/dev/null || ng "通常ターンの exit が 0 でない"
  [ "$(commit_count)" -eq "$((before + 1))" ] || ng "通常ターンでコミットしていない"
  [ "$(calls_count '^claude')" -eq 1 ] || ng "通常ターンで judge を呼んでいない"
  git -C "$WORK" log -1 --pretty=%s | grep -q 'スタブ生成メッセージ' ||
    ng "通常ターンで生成メッセージを使っていない"

  ok "往復中もコミットし、そのときだけ judge を呼ばない"
  ;;

# ---------------------------------------------------------------------------
# 停止条件 (判定器より手前の層)
# ---------------------------------------------------------------------------

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
  # 署名をテスト側で再計算しない(実装と二重管理になる)。
  # 1 回目で hook 自身に last_sig を打たせ、何も変えずに 2 回目を回す。
  goalgate >/dev/null 2>&1 || ng "1 回目の exit が 0 でない"
  [ "$(goal_field status)" = "active" ] || ng "1 回目で止まってしまった"
  goalgate >/dev/null 2>&1
  [ "$?" -eq 0 ] || ng "無進捗の上限到達時の exit が 0 でない"
  [ "$(goal_field status)" = "stalled" ] || ng "status が stalled になっていない"
  ok "無進捗の継続で stalled になる"
  ;;

# 停止条件 4: ループ自身の記帳 (.claude/loop/) は「前進」に数えない
# 判定履歴や台帳を署名に含めると、完全に停滞していても毎ラウンド署名が変わり、
# 停止条件 4 が丸ごと死ぬ。判定履歴をプロジェクト内に移したときに実際に踏んだ回帰。
goal-no-progress-ignores-ledger)
  init_git
  git -C "$WORK" checkout -q -b feature/loop
  write_goal 2 "$(date +%s)" 600
  # 台帳を追跡対象にする = 最も壊れやすい構成 (.gitignore していないプロジェクト)
  mkdir -p "$WORK/.claude/loop"
  echo '{"ts":"x","event":"start"}' >"$WORK/.claude/loop/run-log.jsonl"
  git -C "$WORK" add -A
  git -C "$WORK" commit -qm ledger

  # 何もしないターンを繰り返す。goal-gate 自身が毎ラウンド判定履歴を書く
  for _ in 1 2 3 4; do
    goalgate >/dev/null 2>&1
    [ "$(goal_field status)" = "stalled" ] && break
  done
  [ "$(goal_field status)" = "stalled" ] ||
    ng "ループ自身の記帳を前進と誤認して止まらない (round=$(goal_field round), no_progress=$(goal_field no_progress))"
  # 記帳が実際に発生していたことの確認 (していなければテストが無意味)
  [ -s "$WORK/.claude/loop/judge-log.jsonl" ] || ng "判定履歴が書かれていない (前提が崩れている)"
  ok "ループ自身の記帳は前進に数えない"
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

# ---------------------------------------------------------------------------
# auto-commit.sh
# ---------------------------------------------------------------------------

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
# (差し戻しの往復中は「動く」に変わった。auto-commit-inner-loop を参照)
auto-commit-skip)
  init_git
  echo "変更" >>"$WORK/seed.txt"

  # main では動かない (rules/git-workflow.md の「main に直接コミットしない」)
  git -C "$WORK" branch -M main
  before=$(commit_count)
  autocommit >/dev/null
  [ "$(commit_count)" -eq "$before" ] || ng "main でコミットしてしまった"

  # 変更が無ければ何もしない
  git -C "$WORK" checkout -q -b feature/y
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

  ok "main / 無変更 / マージ途中では動かない"
  ;;

# 自動コミット: ループ自身の記帳はコミットしないが、作業は必ずコミットする
auto-commit-ignores-ledger)
  init_git
  git -C "$WORK" checkout -q -b feature/loop
  mkdir -p "$WORK/.claude/loop"

  # (1) 記帳が追跡されている構成 (.gitignore していないプロジェクト)
  echo '{"ts":"x"}' >"$WORK/.claude/loop/run-log.jsonl"
  echo w1 >"$WORK/feature.txt"
  git -C "$WORK" add -A && git -C "$WORK" commit -qm base
  before=$(commit_count)
  echo '{"ts":"y"}' >>"$WORK/.claude/loop/run-log.jsonl"
  echo w2 >>"$WORK/feature.txt"
  autocommit >/dev/null || ng "(1) exit が 0 でない"
  [ "$(commit_count)" -eq "$((before + 1))" ] || ng "(1) 作業がコミットされていない"
  git -C "$WORK" show --name-only --oneline HEAD | grep -q 'feature.txt' || ng "(1) 作業が含まれていない"
  git -C "$WORK" show --name-only --oneline HEAD | grep -q 'run-log' && ng "(1) 台帳をコミットした"

  # (2) 記帳が .gitignore されている構成 (推奨構成)。
  # add の pathspec に :(exclude) を書くと git add が exit 1 になり、
  # || exit 0 で**何もコミットしなくなる**。その退行をここで捕まえる。
  printf '.claude/goal.md\n.claude/loop/\n' >"$WORK/.gitignore"
  git -C "$WORK" rm -r -q --cached .claude/loop >/dev/null 2>&1
  echo dummy >"$WORK/.claude/goal.md"
  git -C "$WORK" add -A && git -C "$WORK" commit -qm ignore-ledger
  before=$(commit_count)
  echo '{"ts":"z"}' >>"$WORK/.claude/loop/run-log.jsonl"
  echo w3 >>"$WORK/feature.txt"
  autocommit >/dev/null || ng "(2) exit が 0 でない"
  [ "$(commit_count)" -eq "$((before + 1))" ] ||
    ng "(2) 記帳が gitignore 済みだと何もコミットしなくなる (git add が pathspec で失敗)"

  ok "記帳は除外しつつ作業は必ずコミットする"
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
