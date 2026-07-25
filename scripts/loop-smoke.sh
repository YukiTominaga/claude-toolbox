#!/bin/bash
# loop-smoke.sh — 実際の Claude Code を通して Stop hook の相互作用を確かめる契約テスト。
# 使い方: ./scripts/loop-smoke.sh
#
# **evals には入れない**。認証・ネットワークが必要で出力が非決定的であり、
# かつ検証対象がこのリポジトリではなく**インストール済みのキャッシュコピー**だから
# (先に version バンプ → claude plugin update を済ませること)。
#
# 何を守っているか: crystal の内側ループは、文書化されていない 2 つのハーネス挙動の
# 上に立っている。どちらもバージョン更新で予告なく変わりうるが、hook を偽の入力で
# 起動する eval では検知できない(実際の Stop イベントを合成できないため)。
#   1. 先頭の Stop hook が exit 2 しても後続の Stop hook が走る
#   2. stop_hook_active は一度差し戻されると true に固定される
#
# 回すタイミング: Claude Code を更新したとき / Stop hook の構成を変えたとき。
# モデルの出力ではなく副作用だけを検証する。
set -u

command -v claude >/dev/null 2>&1 || {
  echo "NG: claude CLI が見つかりません"
  exit 1
}

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

ng() {
  echo "NG: $1"
  exit 1
}

# --- 最小プロジェクト ---
git -C "$WORK" init -q .
git -C "$WORK" config user.email smoke@example.com
git -C "$WORK" config user.name smoke
git -C "$WORK" checkout -q -b feature/smoke
echo seed >"$WORK/seed.txt"
git -C "$WORK" add seed.txt
git -C "$WORK" commit -qm seed

mkdir -p "$WORK/.claude"
echo ".claude/goal.md" >"$WORK/.gitignore"

# L1 検証が走った回数を数えるためのマーカー。project-checks.sh がこれを実行する。
cat >"$WORK/.claude/checks.sh" <<EOF
#!/bin/bash
echo tick >>"$WORK/l1-marker"
exit 0
EOF
chmod +x "$WORK/.claude/checks.sh"

# 2 ラウンド以上かかるゴール。プロンプトでは片方しか頼まないので、
# 1 ラウンド目は必ず未達になり差し戻される。
cat >"$WORK/.claude/goal.md" <<EOF
---
status: active
round: 0
max_rounds: 5
no_progress: 0
max_no_progress: 3
last_sig:
started_epoch:
max_minutes: 10
created: $(date +%Y-%m-%d)
spec:
---
# ゴール: smoke

## 完了条件

- [ ] DC-1: リポジトリ直下に smoke-a.txt が存在する
- [ ] DC-2: リポジトリ直下に smoke-b.txt が存在する
EOF

goal_field() {
  awk -v k="$1" '/^---$/{fm++; next} fm==1 && $0 ~ "^"k":" { sub("^"k": *",""); print; exit }' \
    "$WORK/.claude/goal.md"
}

echo "実行中..."
(cd "$WORK" && claude -p "smoke-a.txt を作ってください。内容は a の 1 行で十分です。" \
  --max-turns 12 --permission-mode acceptEdits --allowedTools "Write,Read,Edit" \
  --output-format json --no-session-persistence >"$WORK/out.json" 2>"$WORK/err.log")

cost=$(jq -r '.total_cost_usd // 0' "$WORK/out.json" 2>/dev/null)
subtype=$(jq -r '.subtype // "?"' "$WORK/out.json" 2>/dev/null)
turns=$(jq -r '.num_turns // 0' "$WORK/out.json" 2>/dev/null)
round=$(goal_field round)
status=$(goal_field status)
markers=$(wc -l <"$WORK/l1-marker" 2>/dev/null | tr -d ' ')
commits=$(git -C "$WORK" rev-list --count HEAD 2>/dev/null)
[ -n "$markers" ] || markers=0

echo "round=$round status=$status L1実行=$markers コミット=$commits ターン=$turns 終了=$subtype コスト=\$$cost"

# 1. 差し戻しが実際に起きた = Stop hook の exit 2 が停止をブロックしている
[ "${round:-0}" -ge 2 ] 2>/dev/null ||
  ng "差し戻しが起きていない (round=$round, 終了=$subtype)。exit 2 が効いていないか、ターン上限が先に来た"

# 2. 差し戻しの往復ラウンドでも L1 が走った = 今回塞いだ床が実環境でも効いている
[ "$markers" -ge 2 ] || ng "L1 検証が $markers 回しか走っていない (2 回以上を期待)。往復ラウンドで抜けている"

# 3. 内側ループ中にコミットが積まれた
[ "${commits:-0}" -ge 2 ] || ng "内側ループ中にコミットされていない (commits=$commits)"

# 4. 暴走していない = goal-gate 自身のラウンド上限を超えていない
# (status が done / stalled まで行くかはモデルの収束次第なので、ここでは条件にしない。
#  ハーネス契約として確かめたいのは 1〜3 と「上限を超えないこと」)
max_rounds=$(goal_field max_rounds)
[ "${round:-0}" -le "${max_rounds:-5}" ] ||
  ng "ラウンド上限 ($max_rounds) を超えて回った (round=$round)"

echo "OK: 差し戻し $round ラウンド、L1 $markers 回、コミット $commits 件、status=$status"
