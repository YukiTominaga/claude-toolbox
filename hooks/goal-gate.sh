#!/bin/bash
# goal-gate.sh — ゴール達成の自動判定ゲート (Loop Engineering の内側ループ)
# Claude が応答を終えようとしたとき、.claude/goal.md (status: active) があれば
# Haiku で完了条件の達成を判定し、未達なら exit 2 で差し戻す。
#
# stop-gate.sh と異なり stop_hook_active では素通ししない(意図的な差異):
# 差し戻し後の再停止でも毎回判定するのがこのゲートの目的であり、
# 暴走防止は以下の停止条件 4 層が担う:
#   1. done-check   完了条件をすべて満たしたと判定 → status: done
#   2. 反復上限     round > max_rounds → status: stalled
#   3. 予算         経過時間 > max_minutes → status: stalled
#   4. 無進捗       差分が変わらないラウンドが max_no_progress 回続く → status: stalled
set -u

# --- 再帰防止: 内側の claude -p (judge) から起動された場合は素通し ---
if [ "${CRYSTAL_GOAL_JUDGE:-}" = "1" ]; then
  exit 0
fi

# --- プラグインルートの解決は cd より前に行う ---
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

input=$(cat)

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

GOAL=".claude/goal.md"
[ -f "$GOAL" ] || exit 0

# 判定履歴はプロジェクト内の台帳と同じ場所に置く。$HOME 配下に置くと全プロジェクトの
# 履歴が 1 ファイルに混ざり、eval スイートの warn 行まで実プロジェクトに混入する。
LOG_DIR=".claude/loop"
LOG="$LOG_DIR/judge-log.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null

warn() {
  printf '{"ts":"%s","level":"warn","msg":"%s"}\n' "$(date -Iseconds)" "$1" >>"$LOG" 2>/dev/null
}

# frontmatter の値を取得(行末コメントと前後空白を除去)
get_field() {
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" {
      sub("^"k": *", ""); sub(" *#.*$", ""); gsub(/^ +| +$/, ""); print; exit
    }' "$GOAL"
}

# frontmatter の値を書き換え
update_field() {
  awk -v k="$1" -v v="$2" '
    /^---$/ { fm++ }
    fm==1 && $0 ~ "^"k":" { print k": "v; next }
    { print }' "$GOAL" >"$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
}

# frontmatter にキーが存在するか
has_field() {
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $0 ~ "^"k":" { found=1 }
    END { exit !found }' "$GOAL"
}

# キーが無ければ frontmatter の末尾に追加する(旧形式の goal.md との後方互換)
ensure_field() {
  has_field "$1" && return 0
  awk -v line="$1: $2" '
    /^---$/ { fm++; if (fm==2 && !done) { print line; done=1 } }
    { print }' "$GOAL" >"$GOAL.tmp" && mv "$GOAL.tmp" "$GOAL"
}

status=$(get_field status)
[ "$status" = "active" ] || exit 0

ensure_field no_progress 0
ensure_field max_no_progress 2
ensure_field last_sig ""
ensure_field started_epoch ""
ensure_field max_minutes 60

round=$(get_field round)
max_rounds=$(get_field max_rounds)
case "$round" in '' | *[!0-9]*) round=0 ;; esac
case "$max_rounds" in '' | *[!0-9]*) max_rounds=5 ;; esac

# --- 判定前にラウンドを進めて永続化(判定がクラッシュしてもカウントを失わない) ---
round=$((round + 1))
update_field round "$round"

if [ "$round" -gt "$max_rounds" ]; then
  update_field status stalled
  printf '{"systemMessage":"goal-gate: ラウンド上限 (%s) に達したため自動判定を停止しました (status: stalled)。/crystal:goal status で確認してください。"}\n' "$max_rounds"
  exit 0
fi

# --- 停止条件 3: 壁時計予算 ---
# トークン課金額はシェルから観測できないため、予算は経過時間で表現する。
# 開始時刻はこのフックが初回ラウンドで打刻する(date +%s は環境差がなく移植性が高い)。
now_epoch=$(date +%s 2>/dev/null)
started_epoch=$(get_field started_epoch)
max_minutes=$(get_field max_minutes)
case "$max_minutes" in '' | *[!0-9]*) max_minutes=60 ;; esac
case "$started_epoch" in
'' | *[!0-9]*)
  [ -n "$now_epoch" ] && update_field started_epoch "$now_epoch"
  ;;
*)
  if [ -n "$now_epoch" ] && [ "$max_minutes" -gt 0 ]; then
    elapsed_min=$(((now_epoch - started_epoch) / 60))
    if [ "$elapsed_min" -ge "$max_minutes" ]; then
      update_field status stalled
      printf '{"systemMessage":"goal-gate: 予算 (%s 分) を超えたため自動判定を停止しました (経過 %s 分, status: stalled)。/crystal:goal status で確認してください。"}\n' \
        "$max_minutes" "$elapsed_min"
      exit 0
    fi
  fi
  ;;
esac

# --- 停止条件 4: 無進捗検知 ---
# 前ラウンドから状態が変わっていないラウンドは、判定器を呼ばずに差し戻す(コスト削減も兼ねる)。
# git 管理下でない場合は署名が取れないのでこの層はスキップする。
#
# 署名には HEAD を必ず含める: コミット済みの前進を見落とさないため。
# auto-commit フックや「feature ブランチでは自由にコミット」の運用により、ターン終了時の
# 作業ツリーは空であることが普通になる。作業ツリーだけを見ると、コミットを積み続けていても
# 毎ラウンド同一の署名になり、前進を停滞と誤判定して止まる。
#
# 逆に `.claude/loop/` と `.claude/goal.md` は署名から**除外する**。台帳・判定履歴・
# ゴール自身はループの記帳であってエージェントの作業ではない。含めると毎ラウンド署名が
# 変わり、完全に停滞していても「前進している」と誤認して止まらなくなる(= 停止条件 4 が死ぬ)。
# .gitignore に頼らず署名側で除外する: gitignore していないプロジェクトで静かに壊れるため。
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  own=":(exclude).claude/loop"
  own_goal=":(exclude).claude/goal.md"
  sig=$( {
    git rev-parse HEAD
    git diff HEAD -- . "$own" "$own_goal"
    git status --porcelain -- . "$own" "$own_goal"
    # 未追跡ファイルは status に**名前しか出ない**ので、既存の未追跡ファイルへ追記しても
    # 署名が変わらず「進んでいない」と判定される。内容も署名に含める。
    # 通常運転では auto-commit が毎ラウンドコミットして HEAD が動くため表面化しないが、
    # auto-commit が効かない構成 (main ブランチ / 機密パス検出で中止) では前進中に stalled になる。
    #
    # cksum は POSIX で、shasum (perl 同梱) や sha1sum (GNU) と違い環境を選ばない。
    # 読むのは --exclude-standard を通ったファイルだけなので、.gitignore された
    # ビルド成果物や node_modules は入らない。
    # xargs は入力が空だと引数なしで cksum を起動し、cksum は標準入力を読みにいく。
    # このフックでは stdin が既に `input=$(cat)` で読み切られているため実測では即 EOF で
    # 返るが、それは stdin が何であるかに依存した偶然でしかない。空かどうかを先に見て、
    # 挙動を stdin から切り離す (-r は GNU 専用で macOS では使えない)。
    untracked=$(git ls-files --others --exclude-standard -- . "$own" "$own_goal" 2>/dev/null)
    if [ -n "$untracked" ]; then
      printf '%s\n' "$untracked" | tr '\n' '\0' | xargs -0 cksum 2>/dev/null
    fi
  } 2>/dev/null | cksum | tr -d ' ')
  last_sig=$(get_field last_sig)
  no_progress=$(get_field no_progress)
  max_no_progress=$(get_field max_no_progress)
  case "$no_progress" in '' | *[!0-9]*) no_progress=0 ;; esac
  case "$max_no_progress" in '' | *[!0-9]*) max_no_progress=2 ;; esac

  if [ -n "$last_sig" ] && [ "$sig" = "$last_sig" ]; then
    no_progress=$((no_progress + 1))
    update_field no_progress "$no_progress"
    if [ "$no_progress" -ge "$max_no_progress" ]; then
      update_field status stalled
      printf '{"systemMessage":"goal-gate: 差分に変化がないラウンドが %s 回続いたため自動判定を停止しました (status: stalled)。/crystal:goal status で確認してください。"}\n' \
        "$no_progress"
      exit 0
    fi
    printf 'ゴール判定: 前ラウンドから作業ツリーの差分が変化していません (無進捗 %s/%s)。\n完了条件を満たす変更を加えること。これ以上進められない場合は、理由を述べて /crystal:goal abandon を提案すること。\n' \
      "$no_progress" "$max_no_progress" >&2
    exit 2
  fi

  update_field last_sig "$sig"
  if [ "$no_progress" -ne 0 ]; then
    update_field no_progress 0
  fi
fi

# --- L1 検証 (停止条件の後、判定器の前) ---
# 検証ラダーの安い順に並べる。赤なら judge を呼ばずに差し戻す(コストも下がる)。
# 位置は 2 つの制約で決まっており、どちらも eval で固定している:
#   - 停止条件 4 層より「後」: 前に置くと赤の間ずっと exit 2 でラウンド上限に到達せず、
#     このフック自身が無限ループになる (goal-l1-after-stop-rules)
#   - claude の有無を見るより「前」: CLI が無い環境でも L1 だけは残る
#     (goal-l1-blocks-without-claude)
CHECKS="$ROOT/scripts/project-checks.sh"
if [ ! -x "$CHECKS" ]; then
  # 静かに L1 が消える唯一の経路。素通しはするが痕跡は残す
  warn "project-checks.sh が実行可能でないため L1 検証をスキップ ($CHECKS)"
elif ! l1_failed=$("$CHECKS" 2>&1); then
  printf 'L1 検証に失敗しました (ラウンド %s/%s)。完了判定は行いません。\n%s\n修正してから完了と報告すること。\n' \
    "$round" "$max_rounds" "$l1_failed" >&2
  exit 2
fi

# --- 判定材料の収集 ---
# CRYSTAL_JUDGE_CMD が指定されていれば判定器を差し替える(eval が met/unmet の両経路を
# 決定的に踏むために使う)。差し替え先は `claude -p --output-format json` と同じ形の
# JSON を stdout に返すこと。指定が無ければ claude CLI の有無を見る。
if [ -z "${CRYSTAL_JUDGE_CMD:-}" ]; then
  command -v claude >/dev/null 2>&1 || {
    warn "claude CLI が見つからないため判定をスキップ"
    exit 0
  }
fi

transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)

context=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  context=$(tail -n 300 "$transcript_path" |
    jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null |
    tail -c 6000)
fi
# 判定材料には**コミット済みの変更も含める**。auto-commit がターンごとに作業ツリーを
# 空にするため、git status だけを渡すと判定器は「何もしていない」ように見えてしまい、
# 完了しているのに未達と誤判定する(実測: 「smoke-a.txt が git status に表示されていない
# ため確認できない」)。無進捗検知が HEAD を署名に含めているのと同じ理由。
gitinfo=$( {
  echo "### 作業ツリー (git status --short)"
  git status --short 2>/dev/null | head -n 30
  echo "### このゴールの開始以降のコミット (git log --name-status)"
  git log --name-status --oneline -n 10 2>/dev/null | head -n 40
} 2>/dev/null)
conditions=$(awk '/^## 完了条件/{f=1;next} /^## /{f=0} f' "$GOAL")

prompt="あなたはゴール達成の判定器です。以下の完了条件・直近の作業ログ・git の状態を読み、完了条件がすべて満たされたかを判定してください。
出力は次の JSON のみ。説明文・コードフェンスは一切付けないこと:
{\"met\": true|false, \"unmet\": [\"未達の条件ID\"], \"reason\": \"簡潔な理由\"}
判定できない条件・情報が足りない条件は未達として扱うこと。

## 完了条件
${conditions}

## 直近の作業ログ (assistant 出力の末尾)
${context}

## git の状態 (作業ツリーとコミット済みの変更)
${gitinfo}"

# macOS には timeout が無い(GNU coreutils 同梱)。素のまま呼ぶと 127 で必ず失敗し、
# 判定が毎回 fail-open して L4 が丸ごと死ぬ。あれば使い、無ければ付けずに実行する
# (ぶら下がった場合は hooks.json の timeout がバックストップになる)。
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT="timeout 120"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT="gtimeout 120"
else
  TIMEOUT=""
fi

# 判定結果のスキーマ。--json-schema に渡して形を CLI 側に強制させる。
# これにより「JSON 以外が混ざったら正規表現で拾い直す」たぐいの後処理が不要になる。
SCHEMA='{"type":"object","properties":{"met":{"type":"boolean"},"unmet":{"type":"array","items":{"type":"string"}},"reason":{"type":"string"}},"required":["met","unmet","reason"],"additionalProperties":false}'

# --max-budget-usd は判定器自身の暴走止め。実測で 1 回 $0.014〜$0.062 なので十分な余裕がある。
JUDGE="${CRYSTAL_JUDGE_CMD:-}"
if [ -z "$JUDGE" ]; then
  JUDGE="claude -p --model claude-haiku-4-5-20251001 --settings {\"disableAllHooks\":true} --output-format json --max-budget-usd 0.5 --json-schema $SCHEMA"
fi

# --- 判定 (再帰防止は disableAllHooks + env ガードの二重化) ---
# JUDGE は意図的にクォートせず単語分割させる(コマンドと引数列を 1 変数で持つため)。
# 中身は上のリテラルか、eval が渡すスタブのパスのみで、外部入力は入らない。
# shellcheck disable=SC2086
raw=$(printf '%s' "$prompt" | CRYSTAL_GOAL_JUDGE=1 $TIMEOUT $JUDGE 2>>"$LOG") || {
  warn "judge 実行失敗 (round=$round)"
  exit 0
}

# `claude -p --output-format json` は {..., "result": "<JSON文字列>", "total_cost_usd": N} を返す。
# .result の中身が判定結果。スタブや将来の形式変更に備え、外側が剥がせなければ
# raw をそのまま判定結果とみなす。
cost=$(printf '%s' "$raw" | jq -r '.total_cost_usd // 0' 2>/dev/null)
case "$cost" in '' | null) cost=0 ;; esac

if printf '%s' "$raw" | jq -e '.is_error == true' >/dev/null 2>&1; then
  warn "judge がエラーを返した (round=$round, subtype=$(printf '%s' "$raw" | jq -r '.subtype // ""'), cost=$cost)"
  exit 0
fi

json=$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null)
[ -n "$json" ] || json=$raw

met=$(printf '%s' "$json" | jq -r '.met' 2>/dev/null)
if [ "$met" != "true" ] && [ "$met" != "false" ]; then
  warn "judge 出力のパースに失敗 (round=$round, cost=$cost)"
  exit 0
fi

unmet=$(printf '%s' "$json" | jq -r '(.unmet // []) | join(", ")' 2>/dev/null)
reason=$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null)

# --- 判定履歴を記録 (/learn の素材、コストの実測値) ---
printf '%s' "$json" | jq -c --arg ts "$(date -Iseconds)" --arg sid "$session_id" --argjson r "$round" \
  --argjson c "$cost" \
  '{ts:$ts, session_id:$sid, round:$r, met:.met, unmet:(.unmet // []), reason:(.reason // ""), cost_usd:$c}' \
  >>"$LOG" 2>/dev/null

if [ "$met" = "true" ]; then
  update_field status done
  printf '{"systemMessage":"goal-gate: 完了条件をすべて満たしたと判定しました (ラウンド %s/%s)。goal.md を status: done に更新しました。"}\n' "$round" "$max_rounds"
  exit 0
fi

printf 'ゴール判定: 未達 (ラウンド %s/%s)。\n未達条件: %s\n理由: %s\n完了条件を満たすまで作業を続けること。満たしたと考える場合は、実際のコマンド出力など検証可能な根拠を提示すること。\n' \
  "$round" "$max_rounds" "$unmet" "$reason" >&2
exit 2
