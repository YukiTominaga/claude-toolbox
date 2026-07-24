---
description: 完了条件を定義し、Stop hook (goal-gate) による自動達成判定ループを有効化する
---

# /goal — ゴール定義と自動達成判定

`.claude/goal.md` を管理する。このファイルが `status: active` の間、応答完了のたびに
goal-gate hook が Haiku で完了条件の達成を判定し、未達なら差し戻す。

`$ARGUMENTS` に応じて分岐すること:

## `status` の場合

`.claude/goal.md` を読み、status / round / max_rounds / 完了条件の一覧を報告して終了する。
ファイルがなければ「アクティブなゴールはない」と報告する。

## `done` の場合

`.claude/goal.md` の `status:` を `done` に書き換える(通常は goal-gate が達成判定時に
自動で行うため、これは手動完了用の保険)。`.claude/goals/archive/YYYY-MM-DD-<slug>.md`
への移動を提案する。

## `abandon` の場合

`status:` を `abandoned` に書き換え、自動判定が停止したことを報告する。

## 引数なし、またはタスク説明の場合(ゴール新規作成)

1. `.claude/goal.md` が既に `status: active` で存在する場合は、その内容を提示し、
   上書きしてよいかユーザーに確認する
2. `docs/spec/*.md` を探す:
   - `ステータス: approved` の仕様があれば、その受け入れ条件(AC-*)を完了条件として
     インポートする。複数あればどれを使うかユーザーに選択させ、frontmatter の `spec:`
     に取り込み元のパスを記録する
   - なければ、ここまでの会話とタスク内容から完了条件の草案を作り、ユーザーに確認する
3. 完了条件はすべて検証可能な形(実行できるコマンド・観測できる挙動)で書く。
   検証不能な条件(「きれいにする」等)はユーザーと具体化してから採用する
4. `max_rounds`(判定回数の上限、既定 5)をユーザーに確認する
5. テンプレート(templates/goal.md)の形式で `.claude/goal.md` を作成する。
   `round: 0`、`status: active`、`created:` は今日の日付
6. `.claude/goal.md` が `.gitignore` に含まれていなければ追加を提案する
   (untracked のままだと stop-gate の「変更なし判定」を汚染するため)
7. 最後に宣言する: 「以降、応答完了のたびに Haiku が達成判定を行い、未達なら
   差し戻されます。ラウンド上限 (max_rounds) に達すると status: stalled で停止します。
   停止したい場合は /crystal:goal abandon」

$ARGUMENTS
