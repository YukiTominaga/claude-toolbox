<!-- ループ契約テンプレート。プロジェクト直下に LOOP.md として配置する。
     /crystal:loop next はこのファイルを読んで 1 イテレーションを回す。
     周期実行そのものは組み込みの /loop や Routines に任せる(このファイルは契約だけを持つ)。 -->
---
status: active            # active | paused (paused の間 /crystal:loop next は何もしない)
issue_labels:             # 任意: /crystal:loop refill が拾う GitHub Issue のラベル (カンマ区切り)
---
<!-- 実行回数・経過時間・金額による予算はここに書かない (crystal 本体で撤廃済み。
     docs/spec/budget-removal.md)。対話セッションでは人が見ているので予算は邪魔になるだけで、
     無人実行の歯止めは scripts/loop-run.sh がスクリプト内の定数として持つ。
     このファイルはループ自身が編集できるため、ここに書いた上限は自分で緩められる。 -->
# ループ契約

## 1. トリガー (cadence)

<!-- いつ回るか。手動から始め、段階的に上げる:
     - 手動:   必要なときに /crystal:loop next を叩く
     - 対話中: /loop <間隔> /crystal:loop next (組み込みの /loop に委譲)
     - 無人:   cron / launchd から ./scripts/loop-run.sh (登録は人が行う)

     **昇格の条件はその場で判定できる形で書くこと**。「実績ができたら」のような
     条件は誰も判定できず、いつまでも昇格しないか根拠なく昇格するかになる。
     例: 「判定履歴に met:false が 1 件以上あり、直近 3 件の結果がすべて done」 -->

## 2. 作業範囲 (bounded / unbounded)

<!-- 1 イテレーションで触れてよい**ファイルの範囲**。bounded から始めること。
     bounded = 対象ディレクトリ・変更行数・触ってよいファイル種別が事前に決まっている状態。
     unbounded への昇格は、verifier が「自分が見つけたはずの失敗」を実際に検知できた
     実績で獲得する。
     注意: これは「どこまで探索してよいか」(収束型 / 探索型)とは別の軸。
     探索の広さは .claude/goal.md の完了条件の書き方で決める。 -->

- 触れてよい範囲:
- 触れてはいけない範囲:

## 3. 発見源 (discover)

<!-- ループが次の仕事を見つける場所。上から順に探す。 -->

1. `docs/backlog.md` の未着手項目(先頭から 1 件)
2. `issue_labels` に一致する GitHub Issue(`/crystal:loop refill` で backlog に取り込む)

## 4. 検証 (verifier)

<!-- 何をどのレベルで検証するか。レベルの定義は rules/verification.md を参照。
     タスクが許す限り低い(=決定的な)レベルに留めること。 -->

| 対象 | レベル | 手段 |
|---|---|---|
| 変更ファイルの構文・規約 | L2 | lint-changed / stop-gate |
| 振る舞い | L1–L3 | プロジェクトのテスト / evals の command 型 |
| 完了条件の達成 | L4 | goal-gate (Haiku 判定) |
| 下記ゲートに該当する操作 | L5 | 人間承認 |

## 5. 停止条件 (stop rules)

<!-- 挙げた層すべてを効かせる。単独の層に頼らない。
     goal-gate が駆動する内側ループの停止条件は done-check / 反復上限 / 無進捗 の 3 層。
     外側ループの停止は status: paused (人が倒すスイッチ) と、無人実行のターン数上限
     (scripts/loop-run.sh の定数) が担う。
     実行回数・経過時間・金額による停止は crystal 本体で撤廃済み
     (docs/spec/budget-removal.md)。 -->

- **done-check**: goal-gate が完了条件を「達成」と判定 → `status: done`
- **反復上限**: `.claude/goal.md` の `max_rounds`(既定 5)
- **無進捗**: 差分が変わらないラウンドが `max_no_progress` 回続いたら `status: stalled`
- **手動停止**: frontmatter の `status: paused`
- **無人実行のターン数**: `scripts/loop-run.sh` の定数

## ゲート (人間承認が必要な操作)

<!-- ここに挙げた操作は、ループが自動で実行してはならない。
     無人ループは承認を待てないので、ゲートに置いた操作は実質「実行しない」と同義になる。
     push をゲートに含めるかは環境で判断する。使い捨てのリモート環境では push しないと
     成果が失われる。不可逆なのは merge であって push ではないため、
     迷うならゲートは merge 側に置く。 -->

- リモートへの push / PR の作成・マージ
- 依存関係の追加・更新
- マイグレーション、データ削除、本番環境に影響する操作
- スコープ外のファイルへの変更
