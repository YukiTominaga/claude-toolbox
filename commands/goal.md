---
description: 完了条件を定義し、Stop hook (goal-gate) による自動達成判定ループを有効化する
---

# /goal — ゴール定義と自動達成判定

`.claude/goal.md` を管理する。このファイルが `status: active` の間、応答完了のたびに
goal-gate hook が Haiku で完了条件の達成を判定し、未達なら差し戻す。

`$ARGUMENTS` に応じて分岐すること:

## `status` の場合

`.claude/goal.md` を読み、status / round / max_rounds / no_progress / max_no_progress と
完了条件の一覧を報告して終了する。`status: stalled` の場合は、3 つの停止条件
(達成 / 反復上限 / 無進捗)のどれで止まったのかを frontmatter から判断して伝える。
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
   検証不能な条件(「きれいにする」等)はユーザーと具体化してから採用する。

   **収束型か探索型かを決めるのはここ**(`LOOP.md` の「2. 作業範囲」は触ってよいファイルの
   話であって、探索の広さの話ではない):
   - **収束型**: 測定可能な `DC-*` だけを並べる。指定どおりのものが出る。既定はこちら
   - **探索型**: 測定可能な `DC-*` を**床として全部残したうえで**、その上に
     「見出しは自分で考えてよい」のような開いた指示を 1 行足す。
     こうすると探索しても標準を下回らない

   開いた指示だけを書いて測定可能な条件を省くことはしない。判定器が「良くなった」を
   判定できず、ラウンド上限まで回り続けて費用だけが出る
4. 停止条件の上限をユーザーに確認する:
   - `max_rounds`(判定回数の上限、既定 5)
   - `max_no_progress`(差分が変わらないラウンドの許容回数、既定 2)は通常そのままでよい

   経過時間による停止は撤廃した (`docs/spec/budget-removal.md`)。時間で切りたい場合は
   人が `/crystal:goal abandon` で止める
5. テンプレート(templates/goal.md)の形式で `.claude/goal.md` を作成する。
   `round: 0`、`no_progress: 0`、`status: active`、`created:` は今日の日付。
   `last_sig` は**空のままにする**(goal-gate が自動で埋める)
6. `.claude/goal.md` が `.gitignore` に含まれていなければ追加を提案する
   (untracked のままだと stop-gate の「変更なし判定」を汚染するため)
7. 最後に宣言する: 「以降、応答完了のたびに Haiku が達成判定を行い、未達なら
   差し戻されます。停止条件は 3 層です(達成 / ラウンド上限 max_rounds /
   無進捗 max_no_progress)。いずれかに触れると
   status: stalled で自動判定は止まります。手動で止めたい場合は /crystal:goal abandon」

$ARGUMENTS
