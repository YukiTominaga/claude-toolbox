---
status: active
round: 0
max_rounds: 5
no_progress: 0
max_no_progress: 2
last_sig:
created: YYYY-MM-DD
spec:
---
# ゴール: <タイトル>

## 完了条件

<!-- goal-gate hook が応答完了のたびにこの項目を Haiku で判定する。
     必ず検証可能な形(実行できるコマンド・観測できる挙動)で書くこと。
     判定より手前で型・lint・テスト (L1) が毎ラウンド走り、赤なら判定器を呼ばずに
     差し戻す。ここに「テストが通ること」を書く必要はない。
     frontmatter の意味:
       status:          active | done | stalled | abandoned (active 以外は判定しない)
       round:           hook が判定のたびにインクリメントする。手動で編集しない
       max_rounds:      [停止条件 2] この回数を超えたら status: stalled で自動判定を停止
       no_progress:     差分に変化がなかった連続ラウンド数。hook が更新する。手動で編集しない
       max_no_progress: [停止条件 3] 差分が変わらないラウンドがこの回数続いたら status: stalled
       last_sig:        直近ラウンドの作業ツリー差分の署名。hook が更新する。手動で編集しない
       spec:            取り込み元の仕様ファイル(任意) 例: docs/spec/foo.md
     経過時間による停止は撤廃した (docs/spec/budget-removal.md)。時間で切りたい場合は
     人が /crystal:goal abandon で止める。
     [停止条件 1] は完了条件をすべて満たしたと判定されること (status: done)。 -->

- [ ] DC-1:
- [ ] DC-2:
