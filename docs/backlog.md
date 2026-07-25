<!-- リポジトリ内キュー。git でバージョン管理する。
     /crystal:loop next が上から順に未着手 (- [ ]) の 1 件を取り出す。
     1 行 1 項目。行末の HTML コメントに任意のメタデータを key: value で書ける。
       spec:     取り込み元の仕様ファイル(あれば /crystal:spec を省略できる)
       priority: high | med | low (並べ替えは人間が行う。ループは常に先頭から取る)
     完了したら - [x] に変える。ループ自身も完了時にここを更新する。

     追記は /crystal:loop add(内部で scripts/loop-add.sh が採番する)を使い、
     行を手で書き足さない。項目の粒度のルール:
       - それ単体で「終わったかどうか」を判定できること
         (途中状態にしかならない作業は分割せず、前後の項目に統合する)
       - 依存関係は並び順で表現する(ループは常に先頭から取るため)
       - 実装手段(使う関数・変更するファイル)は書かない。着手までに陳腐化し、
         古い手段を忠実に実装させてしまう。手段が要るなら spec に切り出して参照する -->

# 見送り(backlog に積み直さない)

<!-- キューより「上」に置くこと。loop-add.sh はファイル末尾に無条件で追記するため、
     下に置くと次に積んだ項目がこの節に紛れ込む。
     チェックボックスも付けないこと。付けると loop-next.sh がキューの項目として拾う
     (採番には影響しない。loop-add.sh は - [ ] / - [x] の行からしか最大値を取らない)。 -->

- Q-9: project-checks.sh の署名メモ化 — 二重実行自体は事実だが、eval スイート 50 ケースの実測が 1 回 17 秒。往復ラウンドで 2 回走っても 34 秒で、max_minutes_per_run: 30 に対して無視できる。スイートが数分規模になったら積み直す
- Q-18: .claude/settings.local.json の死んだ allow ルール掃除 — gitignore 対象なので無進捗署名に映らず、内側ループが 2 ラウンド目に stalled で落ちる。eval も書けず、かつ Bash の許可リストなのでループに編集させると自己権限付与の経路になる。人が手で行う

# バックログ
- [x] Q-1: 記録先を整理し docs/signals/ を発見の置き場に一本化する  <!-- priority: high -->
- [x] Q-2: 台帳を loop next の冒頭で読み戻す (loop-log.sh --recent)  <!-- priority: high -->
- [x] Q-3: 判定器を構造化出力にし、コストを記録し、スタブ可能にする  <!-- priority: med -->
- [x] Q-4: open/closed の用語衝突を解消する  <!-- priority: med -->
- [x] Q-5: 無人実行のエントリポイントと実費予算を用意する  <!-- priority: high -->
- [x] Q-6: README の Loop Engineering 節に、記録先4つの表を追記する  <!-- priority: med -->
- [x] Q-7: goal.md の無いセッションで、押し戻し後に stop-gate が二度と検証しない穴を塞ぐ  <!-- priority: high -->
- [x] Q-8: 未追跡ファイルへの追記が無進捗検知に映らない問題に対処する (S-4)  <!-- priority: med -->
- [x] Q-11: LOOP.md の作業範囲に docs/ と LOOP.md 本文を含め、frontmatter の予算と status の変更をゲート節に明記する  <!-- priority: high -->
- [x] Q-23: 内側ループの時間予算 (max_minutes_per_run) を撤廃し、停止条件を 3 層に詰める  <!-- spec: docs/spec/budget-removal.md, priority: high -->
- [ ] Q-24: 外側ループの回数予算を撤廃し、無人実行のターン上限を LOOP.md の宣言から定数に移す  <!-- spec: docs/spec/budget-removal.md, priority: high -->
- [ ] Q-19: stop-gate の差し戻しカウントの書き込みを原子的にする  <!-- priority: med -->
- [ ] Q-17: rubric 型 eval が timeout 不在の環境で必ず SKIP になる問題を直す  <!-- priority: med -->
- [ ] Q-16: 仕様のステータス表記を統一し、approved の自動インポートを機能させる  <!-- priority: med -->
- [ ] Q-12: 予算ゲートを迂回できる経路をなくし、台帳の実行回数を実イテレーション数と一致させる  <!-- priority: high -->
- [ ] Q-13: Stop hook の実行順に依存しない形で、auto-commit と他の Stop hook の競合を防ぐ  <!-- priority: high -->
- [ ] Q-14: 無人実行の初回登録がログを残さず空振りする問題を直す  <!-- priority: med -->
- [ ] Q-15: 無人化への昇格条件を、達成可能かつその場で判定できる形に直す  <!-- priority: med -->
- [ ] Q-22: 台帳に新しい行種を追加するときの手順を文書化する  <!-- priority: low -->
- [ ] Q-20: hooks.json の MultiEdit matcher が現行 Claude Code に存在しないツールを指している問題を直す  <!-- priority: low -->
- [ ] Q-10: frontmatter を読む 5 つのパーサ (get_field 3 + goal_field 2) に、なぜその正規表現かを 1 行コメントで残す  <!-- priority: low -->
- [ ] Q-21: README と実装の食い違いを解消する (hook 本数・scripts 一覧・stop-gate 説明・台帳の書き手、および「一括 add は git-workflow.md の禁止に対する例外」という誤り — 同じ誤りが hooks/auto-commit.sh のコメントにもあるので両方直す)  <!-- priority: low -->
- [ ] Q-25: LOOP.md の作業範囲に .claude/ 配下のパス別の扱いを書く  <!-- priority: med -->
