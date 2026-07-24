---
status: active
round: 0
max_rounds: 5
no_progress: 0
max_no_progress: 2
last_sig:
started_epoch:
max_minutes: 60
created: YYYY-MM-DD
spec:
---
# ゴール: <タイトル>

## 完了条件

<!-- goal-gate hook が応答完了のたびにこの項目を Haiku で判定する。
     必ず検証可能な形(実行できるコマンド・観測できる挙動)で書くこと。
     frontmatter の意味:
       status:          active | done | stalled | abandoned (active 以外は判定しない)
       round:           hook が判定のたびにインクリメントする。手動で編集しない
       max_rounds:      [停止条件 2] この回数を超えたら status: stalled で自動判定を停止
       no_progress:     差分に変化がなかった連続ラウンド数。hook が更新する。手動で編集しない
       max_no_progress: [停止条件 4] 差分が変わらないラウンドがこの回数続いたら status: stalled
       last_sig:        直近ラウンドの作業ツリー差分の署名。hook が更新する。手動で編集しない
       started_epoch:   初回ラウンドで hook が打刻する開始時刻 (epoch 秒)。手動で編集しない
       max_minutes:     [停止条件 3] 開始からこの分数を超えたら status: stalled
       spec:            取り込み元の仕様ファイル(任意) 例: docs/spec/foo.md
     [停止条件 1] は完了条件をすべて満たしたと判定されること (status: done)。 -->

- [ ] DC-1:
- [ ] DC-2:
