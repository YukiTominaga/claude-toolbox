#!/bin/bash
# goal-gate.sh — ゴール達成の自動判定ゲート (Loop Engineering の /goal 相当)
# Claude が応答を終えようとしたとき、.claude/goal.md (status: active) があれば
# Haiku で完了条件の達成を判定し、未達なら exit 2 で差し戻す。
#
# stop-gate.sh と異なり stop_hook_active では素通ししない(意図的な差異):
# 差し戻し後の再停止でも毎回判定するのがこのゲートの目的であり、
# 無限ループ防止は round カウンタ + max_rounds が担う。
set -u

# --- 再帰防止: 内側の claude -p (judge) や検証コマンドから起動された場合は素通し ---
# 検証コマンドが claude セッションを起こすケース (例: eval-run.sh) でも再入しない。
if [ "${CRYSTAL_GOAL_JUDGE:-}" = "1" ] || [ "${CRYSTAL_GOAL_VERIFY:-}" = "1" ]; then
  exit 0
fi

input=$(cat)

# --- プロジェクトルートへ移動 ---
# `cd .` は必ず成功するため `cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0` ではガードにならず、
# CLAUDE_PROJECT_DIR 未設定時にカレント次第で .claude/goal.md を見失う。
# 未設定なら git のトップレベルにフォールバックする。
project_dir="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project_dir" ]; then
  project_dir=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
cd "$project_dir" || exit 0

GOAL=".claude/goal.md"
[ -f "$GOAL" ] || exit 0

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/goal-gate.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null

warn() {
  # メッセージには検証コマンドの原文が入りうる。printf で埋め込むと " や \ で
  # JSON が壊れ、jsonl を読む側(/crystal:learn の差し戻し履歴集計など)が落ちる
  jq -nc --arg ts "$(date -Iseconds)" --arg msg "$1" \
    '{ts:$ts, level:"warn", msg:$msg}' >>"$LOG" 2>/dev/null
}

# 移植性のあるタイムアウト。macOS には coreutils の timeout が無いため perl で代替する
# (timeout が無い環境では judge が exit 127 で必ず失敗し、判定に到達できなくなる)
run_with_timeout() {
  _secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$_secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$_secs" "$@"
  else
    "$@"
  fi
}

# frontmatter の区切りは /^---[[:space:]]*$/ で判定する。厳密一致にすると
# CRLF 改行の goal.md で frontmatter を見失い、ゲートが黙って無効化されるため。

# frontmatter の値を取得(行末コメント・前後空白・CR を除去)
get_field() {
  awk -v k="$1" '
    /^---[[:space:]]*$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" {
      sub("^"k": *", ""); sub(" *#.*$", ""); gsub(/\r/, ""); gsub(/^ +| +$/, ""); print; exit
    }' "$GOAL"
}

# frontmatter の値を書き換える。フィールドが無ければ閉じ --- の直前に追加する
# (旧テンプレートで作られた goal.md にも cost_usd を書けるようにするため)
# 書けなかった場合は非ゼロを返す。呼び出し側は必ず戻り値を見ること:
# round の永続化に失敗したまま進むと、max_rounds に永遠に到達せず無限に差し戻し続ける。
update_field() {
  _tmp=$(mktemp "${GOAL}.XXXXXX" 2>/dev/null) || return 1
  if awk -v k="$1" -v v="$2" '
    /^---[[:space:]]*$/ {
      fm++
      if (fm==2 && !written) { print k": "v; written=1 }
      print; next
    }
    fm==1 && $0 ~ "^"k":" { print k": "v; written=1; next }
    { print }
    END { exit(written ? 0 : 1) }' "$GOAL" >"$_tmp"; then
    mv "$_tmp" "$GOAL"
  else
    rm -f "$_tmp"
    return 1
  fi
}

# judge の自由記述を Markdown の1行に収める。
# 改行が入ると awk が "newline in string" で落ち、判定履歴の追記が丸ごと失われる。
sanitize_line() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# 見出し "## <名前>" 直下のセクション本文を取り出す
get_section() {
  awk -v h="## $1" 'index($0,h)==1 { f=1; next } /^## / { f=0 } f' "$GOAL"
}

# 完了条件から (DC-ID 群, 検証コマンド) の対を取り出す。
# 書式: - [ ] DC-1: <観測可能な終了状態> — 検証: `<コマンド>` が <期待する結果>
# 同一コマンドを参照する DC はまとめる(コマンドは 1 回しか実行しないため)。
# 出力は "<ID, ID, ...>\t<コマンド>" の行。出現順を保つ。
extract_verify_cmds() {
  get_section "完了条件" | awk '
    /^-[[:space:]]*\[[ xX]\]/ {
      line = $0
      # 行内で「検証:」が複数回現れる場合は最後の出現を起点にする。
      # 最初の出現を使うと、説明文が「検証:」とコードスパンを含むときに
      # 本来の検証コマンドではなく説明文中のコードが抽出され、
      # 宣言と違うコマンドを実行したうえで judge には成功として報告してしまう
      p = 0; s = 1
      while ((q = index(substr(line, s), "検証:")) > 0) { p = s + q - 1; s = p + 1 }
      if (p == 0) next
      rest = substr(line, p + length("検証:"))
      a = index(rest, "`")
      if (a == 0) next
      t = substr(rest, a + 1)
      b = index(t, "`")
      if (b == 0) next
      cmd = substr(t, 1, b - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cmd)
      if (cmd == "") next
      id = line
      sub(/^-[[:space:]]*\[[ xX]\][[:space:]]*/, "", id)
      c = index(id, ":")
      if (c > 0) id = substr(id, 1, c - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
      if (id == "") id = "?"
      if (cmd in ids) { ids[cmd] = ids[cmd] ", " id; next }
      ids[cmd] = id
      order[++n] = cmd
    }
    END { for (i = 1; i <= n; i++) printf "%s\t%s\n", ids[order[i]], order[i] }
  '
}

# 検証コマンドを実行してよいか。goal.md は応答完了のたびに読まれるうえ、
# ここでの実行は Claude Code の Bash ツールを通らない。つまり権限プロンプトも
# PreToolUse (pre-bash-guard.sh) もかからないため、実行してよいコマンドは
# 「コマンド全体が下のパターンのどれかに完全一致するもの」だけに限る。
#
# コマンド名の先頭トークンだけで許可してはいけない: node / python / git / make / go /
# cargo / npx などは引数だけで任意コードを実行できる汎用ランナーであり、
# `node -e '...'` `git -c alias.x='!...' x` `make -f evil.mk` `npx -y <pkg>` が
# 区切り文字もメタ文字も使わずに素通りする。
#
# `npm test` / `npm run <script>` は package.json 側の定義を走らせるが、これは
# stop-gate.sh が既に無条件で行っていることであり、新たなリスクにはならない。
# 一致しなかったコマンドは実行せず、従来どおり judge の読解に委ねる(差し戻しはしない)。
VERIFY_RE='^(npm|pnpm|yarn|bun) (test|run( -s)? [A-Za-z0-9:_-]+)( -- [A-Za-z0-9:._/= -]+)?$'
VERIFY_RE="${VERIFY_RE}|^npx (--no-install )?(vitest run|jest|tsc --noEmit|eslint \.)$"
VERIFY_RE="${VERIFY_RE}|^(vitest run|jest|tsc --noEmit)$"
VERIFY_RE="${VERIFY_RE}|^pytest( -[qxvs]+)*( [A-Za-z0-9._/-]+)*$"
VERIFY_RE="${VERIFY_RE}|^(ruff check|mypy|eslint|shellcheck) [A-Za-z0-9._/ -]+$"
VERIFY_RE="${VERIFY_RE}|^go (test|vet) \./\.\.\.$"
VERIFY_RE="${VERIFY_RE}|^cargo (test|check|clippy)$"
VERIFY_RE="${VERIFY_RE}|^make (test|check|lint)$"
VERIFY_RE="${VERIFY_RE}|^(mvn|gradle) (test|verify|check)$"
VERIFY_RE="${VERIFY_RE}|^git (status --porcelain|diff --exit-code|diff --quiet)$"

is_runnable() {
  # 全体一致の許可パターン。文字クラスがメタ文字を含まないため、
  # 区切り文字・引用符・コマンド置換は構造的に一致しえない
  printf '%s' "$1" | grep -qE "$VERIFY_RE"
}

# 「## 判定履歴」に 1 件追記する(直近 5 件を保持)。次ターン以降が読む外部メモリ。
append_history() {
  # entry は ENVIRON 経由で渡す: awk の -v は値のエスケープを展開してしまい、
  # reason に \t や \n が含まれると文字列が壊れる(改行なら awk 自体が落ちる)
  _hist_tmp=$(mktemp "${GOAL}.XXXXXX" 2>/dev/null) &&
    GG_ENTRY="$1" awk -v keep=5 '
    BEGIN { entry = ENVIRON["GG_ENTRY"] }
    { lines[NR]=$0 }
    END{
      start=0
      for (i=1; i<=NR; i++) if (index(lines[i],"## 判定履歴")==1) { start=i; break }
      if (start==0) {
        for (i=1; i<=NR; i++) print lines[i]
        print ""; print "## 判定履歴"; print ""; print entry
        exit
      }
      end=NR
      for (i=start+1; i<=NR; i++) if (index(lines[i],"## ")==1) { end=i-1; break }
      np=0; nh=0
      for (i=start+1; i<=end; i++) {
        if (index(lines[i],"- ")==1) hist[++nh]=lines[i]; else pre[++np]=lines[i]
      }
      hist[++nh]=entry
      first = (nh>keep) ? nh-keep+1 : 1
      for (i=1; i<=start; i++) print lines[i]
      for (i=1; i<=np; i++) print pre[i]
      for (i=first; i<=nh; i++) print hist[i]
      for (i=end+1; i<=NR; i++) print lines[i]
    }' "$GOAL" >"$_hist_tmp" && mv "$_hist_tmp" "$GOAL" || {
    rm -f "$_hist_tmp" 2>/dev/null
    warn "判定履歴の追記に失敗 (round=$round)"
  }
}

# --- frontmatter が壊れている goal.md には触らない ---
# 開始/終了の --- が揃っていないと update_field が黙って何も書けず、
# round が永続化されないまま差し戻しだけが続く
fm_ok=$(awk '
  NR==1 && /^---[[:space:]]*$/ { s=1; next }
  s && /^---[[:space:]]*$/ { e=1; exit }
  END { print (s && e) ? "1" : "0" }' "$GOAL")
if [ "$fm_ok" != "1" ]; then
  warn "goal.md の frontmatter が不正なため判定をスキップ"
  exit 0
fi

status=$(get_field status)
[ "$status" = "active" ] || exit 0

# --- claude CLI の有無はラウンドを消費する前に確認する ---
# (判定できない環境でラウンドだけ減り、判定ゼロのまま stalled に落ちるのを防ぐ)
command -v claude >/dev/null 2>&1 || {
  warn "claude CLI が見つからないため判定をスキップ"
  exit 0
}

round=$(get_field round)
max_rounds=$(get_field max_rounds)
case "$round" in '' | *[!0-9]*) round=0 ;; esac
case "$max_rounds" in '' | *[!0-9]*) max_rounds=5 ;; esac
# 桁あふれで $((round + 1)) が負値になり上限判定をすり抜けるのを防ぐ
[ "${#round}" -gt 9 ] && round=0
[ "${#max_rounds}" -gt 9 ] && max_rounds=5

# --- 判定前にラウンドを進めて永続化(判定がクラッシュしてもカウントを失わない) ---
round=$((round + 1))
if ! update_field round "$round"; then
  warn "round の永続化に失敗したため判定をスキップ (frontmatter 不正または書き込み不可)"
  exit 0
fi

if [ "$round" -gt "$max_rounds" ]; then
  update_field status stalled
  printf '{"systemMessage":"goal-gate: ラウンド上限 (%s) に達したため自動判定を停止しました (status: stalled)。/crystal:goal status で判定履歴を確認し、条件を見直して /crystal:goal resume で再開してください。実態の確認には crystal:verifier が使えます。"}\n' "$max_rounds"
  exit 0
fi

transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

# --- 完了条件に併記された検証コマンドを実際に実行する ---
# judge は会話ログしか読めないため、テキストだけでは「本当に通っているのか」も
# 「出力を貼り忘れただけなのか」も確定できない。ここで機械的に事実を確定させる。
# 失敗が確定した時点で judge を呼ばずに差し戻す(そのラウンドの judge コストを払わない)。
TAB=$(printf '\t')
verify_report=""
verify_detail=""
verify_unmet=""
verify_failed=0

# goal.md が git 管理下にあるなら、その内容はリポジトリ由来であってこの環境の作業者が
# 書いたものとは限らない。clone しただけで任意のコマンドが走るのを防ぐため実行しない。
# (README は .claude/goal.md を .gitignore に入れる運用を前提にしている)
verify_enabled=1
if git ls-files --error-unmatch "$GOAL" >/dev/null 2>&1; then
  warn "goal.md が git 管理下にあるため検証コマンドを実行しない"
  verify_enabled=0
fi

# hook 全体のタイムアウト(hooks.json で 600 秒)に judge の分を残すための予算。
# 予算を使い切ったら残りは未実行として judge に渡す。
# 予算を持たずに走らせると、round を消費したまま hook がランタイムに打ち切られ、
# 判定が 1 度も記録されないまま max_rounds に達して stalled に落ちる
VERIFY_BUDGET=240
SECONDS=0

export CRYSTAL_GOAL_VERIFY=1
while IFS="$TAB" read -r dc_ids cmd; do
  [ -n "$cmd" ] || continue
  skip_reason=""
  if [ "$verify_enabled" = "0" ]; then
    skip_reason="未実行 (goal.md が git 管理下にあるため goal-gate は実行しない)"
  elif ! is_runnable "$cmd"; then
    warn "検証コマンドが許可パターンに一致しないため実行しない: $cmd"
    skip_reason="未実行 (goal-gate の許可パターン外。実行の有無は作業ログから判断すること)"
  elif [ "$SECONDS" -ge "$VERIFY_BUDGET" ]; then
    skip_reason="未実行 (検証の時間予算 ${VERIFY_BUDGET} 秒を使い切った)"
  fi
  if [ -n "$skip_reason" ]; then
    verify_report="${verify_report}
### ${dc_ids}: \`${cmd}\`
${skip_reason}"
    continue
  fi
  _left=$((VERIFY_BUDGET - SECONDS))
  [ "$_left" -gt 120 ] && _left=120
  # stdin は必ず /dev/null に向ける: 既定では下の heredoc をそのまま継承するため、
  # 検証コマンドが stdin を読むと残りの DC 行を食い、2 件目以降が黙って未実行になる
  out=$(run_with_timeout "$_left" bash -c "$cmd" </dev/null 2>&1)
  rc=$?
  out=$(printf '%s' "$out" | tail -c 2000)
  verify_report="${verify_report}
### ${dc_ids}: \`${cmd}\`
exit: ${rc}
${out}"
  [ "$rc" -eq 0 ] && continue
  verify_failed=1
  verify_unmet="${verify_unmet:+${verify_unmet}, }${dc_ids}"
  verify_detail="${verify_detail}
--- ${dc_ids}: \`${cmd}\` (exit ${rc}) ---
${out}"
done <<EOF
$(extract_verify_cmds)
EOF
unset CRYSTAL_GOAL_VERIFY

if [ "$verify_failed" = "1" ]; then
  append_history "- r${round}: 未達 [${verify_unmet}] — 検証コマンドが失敗 (goal-gate が実行)"
  jq -nc --arg ts "$(date -Iseconds)" --arg sid "$session_id" --argjson r "$round" \
    --arg unmet "$verify_unmet" \
    '{ts:$ts, session_id:$sid, round:$r, met:false, unmet:($unmet|split(", ")),
      violations:[], reason:"検証コマンドが失敗", cost_usd:0, source:"verify"}' \
    >>"$LOG" 2>/dev/null
  {
    printf 'ゴール判定: 未達 (ラウンド %s/%s)。\n' "$round" "$max_rounds"
    printf '完了条件に併記された検証コマンドを goal-gate が実行し、失敗しました。\n'
    printf '未達条件: %s\n' "$verify_unmet"
    printf '%s\n' "$verify_detail"
    printf 'これを修正するまで完了と報告しないこと。judge はこのラウンドでは呼んでいません。\n'
  } >&2
  exit 2
fi

# --- 判定材料の収集 ---
context=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  context=$(tail -n 300 "$transcript_path" |
    jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null |
    tail -c 6000)
fi
gitinfo=$(git status --short 2>/dev/null | head -n 30)
conditions=$(get_section "完了条件")
constraints=$(get_section "制約")

verify_block=""
verify_rule=""
if [ -n "$verify_report" ]; then
  verify_block="

## 検証コマンドの実測結果 (goal-gate が実際に実行したもの)
${verify_report}"
  verify_rule="
- 「## 検証コマンドの実測結果」に exit: 0 と示された検証コマンドは、goal-gate が実際に実行して成功を確認済みである。作業ログに出力が無くても、そのコマンドが担保する範囲は満たされたものとして扱うこと"
fi

prompt="あなたはゴール達成の判定器です。以下の完了条件・制約・検証コマンドの実測結果・直近の作業ログ・git status を読み、完了条件がすべて満たされたかを判定してください。
出力は次の JSON のみ。説明文・コードフェンスは一切付けないこと:
{\"met\": true|false, \"unmet\": [\"未達の条件ID\"], \"violations\": [\"違反した制約ID\"], \"reason\": \"簡潔な理由\"}

判定の原則:
- あなたは作業ログに書かれた内容しか読めない。コマンドを実行することも、ファイルを直接読むこともできない${verify_rule}
- 実測結果に現れていない条件について、併記された検証コマンドの実際の出力が作業ログにも無い場合は、未達として扱うこと
- 判定できない条件・情報が足りない条件は未達として扱うこと
- 制約に違反していると判断した場合は violations に制約IDを入れること。violations が空でなければ met は false にすること
- アプリケーションコードを変更したのに、テストの追加・更新とその実行結果が作業ログに現れていない場合は未達として扱うこと。ただしドキュメント・設定のみの変更、および既存テストで担保されるリファクタは除く

## 完了条件
${conditions}${verify_block}

## 制約
${constraints}

## 直近の作業ログ (assistant 出力の末尾)
${context}

## git status --short
${gitinfo}"

# --- Haiku による判定 (再帰防止は disableAllHooks + env ガードの二重化) ---
raw=$(printf '%s' "$prompt" | CRYSTAL_GOAL_JUDGE=1 \
  run_with_timeout 120 claude -p --output-format json \
  --model claude-haiku-4-5-20251001 \
  --settings '{"disableAllHooks": true}' 2>>"$LOG") || {
  warn "judge 実行失敗 (round=$round)"
  exit 0
}

# --output-format json のエンベロープから本文とコストを取り出す
result=$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null)
[ -n "$result" ] || result="$raw"
cost=$(printf '%s' "$raw" | jq -r '.total_cost_usd // empty' 2>/dev/null)

# --- 累積コストの更新 (judge の消費を可視化する。記事のコスト爆発対策) ---
# jq は小さい値を 1e-05 の科学記法で出すため、それも受け付ける。
# 逆に 0.1.2 のような不正値は弾く(通すと累積が静かに狂い、ログ行も欠落する)
NUM_RE='^[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$'
printf '%s' "$cost" | grep -qE "$NUM_RE" || cost=""
if [ -n "$cost" ]; then
  cur=$(get_field cost_usd)
  printf '%s' "$cur" | grep -qE "$NUM_RE" || cur=0
  update_field cost_usd "$(awk -v a="$cur" -v b="$cost" 'BEGIN{ printf "%.4f", a+b }')" || true
fi

json=$result
if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
  json=$(printf '%s' "$result" | sed -n '/{/,/}/p')
fi
met=$(printf '%s' "$json" | jq -r '.met' 2>/dev/null)
if [ "$met" != "true" ] && [ "$met" != "false" ]; then
  warn "judge 出力のパースに失敗 (round=$round)"
  exit 0
fi

unmet=$(sanitize_line "$(printf '%s' "$json" | jq -r '(.unmet // []) | join(", ")' 2>/dev/null)")
violations=$(sanitize_line "$(printf '%s' "$json" | jq -r '(.violations // []) | join(", ")' 2>/dev/null)")
reason=$(sanitize_line "$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null)")

# --- 制約違反があれば達成扱いにしない (ゴールドリフト対策) ---
if [ -n "$violations" ]; then
  met=false
fi

# --- 判定履歴を記録 (/learn の素材) ---
printf '%s' "$json" | jq -c \
  --arg ts "$(date -Iseconds)" --arg sid "$session_id" --argjson r "$round" \
  --arg met "$met" --arg cost "${cost:-0}" \
  '{ts:$ts, session_id:$sid, round:$r, met:($met=="true"), unmet:(.unmet // []), violations:(.violations // []), reason:(.reason // ""), cost_usd:($cost|tonumber?)}' \
  >>"$LOG" 2>/dev/null

# --- goal.md の「## 判定履歴」に追記 (直近5件。次ターン以降が読む外部メモリ) ---
if [ "$met" = "true" ]; then
  append_history "- r${round}: 達成 — ${reason}"
else
  append_history "- r${round}: 未達 [${unmet:-?}]${violations:+ 制約違反 [$violations]} — ${reason}"
fi

if [ "$met" = "true" ]; then
  update_field status done
  printf '{"systemMessage":"goal-gate: 完了条件をすべて満たしたと判定しました (ラウンド %s/%s)。goal.md を status: done に更新しました。"}\n' "$round" "$max_rounds"
  exit 0
fi

{
  printf 'ゴール判定: 未達 (ラウンド %s/%s)。\n' "$round" "$max_rounds"
  if [ -n "$unmet" ]; then
    printf '未達条件: %s\n' "$unmet"
  elif [ -n "$violations" ]; then
    printf '未達条件: なし(完了条件は満たしているが制約に違反している)\n'
  else
    printf '未達条件: (未特定)\n'
  fi
  [ -n "$violations" ] && printf '制約違反: %s\n' "$violations"
  printf '理由: %s\n' "$reason"
  printf '完了条件を満たすまで作業を続けること。判定器は会話に出力された内容しか読めないため、満たしたと考える場合は各条件に併記された検証コマンドを実際に実行し、その出力を提示すること。\n'
} >&2
exit 2
