# 仕様: 変更の対を検証する Stop hook (change-gate)

- 日付: 2026-08-08
- 関連 Issue / チケット: —
- ステータス: approved

## 目的(なぜやるか)

crystal のハーネス部分が担うべきは次の 5 つに限られる。

1. 決定の理由を ADR に残す
2. 実装と対になる spec が作られる。機能の変更は spec の変更を伴う
3. 実装とは別の文脈で検証する
4. 実装と対になるテストが必ず書かれる
5. 学びが次のセッションに残る

このうち 2 と 4 は、これまで散文(`rules/testing.md`)と LLM 判定にしか支えられて
いなかった。どちらも「実装ファイルが変わったのに、対になるファイルが 1 つも
変わっていない」という**差分の形**で機械判定できる。判定できることを散文で頼むのは、
`rules/` の採用基準(hook で強制できることは rules に書かない)に反する。

同時に、5 つの目的のどれにも当たらない仕組み(goal ループ / eval / bash ログ /
設定監査 / 破壊コマンドガード / 目的外の rules)を落とし、plugin の面積を目的に合わせる。

## スコープ

### 含む

- `hooks/change-gate.sh` の追加と Stop への登録
- 目的外アセットの削除: `goal-gate.sh`・`/goal`・`templates/goal.md`、
  `eval-run.sh`・`/eval`・`templates/eval-case.md`、`log-bash.sh`、`audit-config.sh`、
  `pre-bash-guard.sh`、`rules/coding-style.md`・`security.md`・`git-workflow.md`
- 削除に伴う参照の除去: `stop-gate.sh` の goal 分岐、`/adr`・`/learn`・`verifier` の
  goal / eval 参照、`/spec` の goal 引き継ぎ
- `rules/testing.md` を「hook が判定できない部分」だけに絞る
- README の再構成(5 つの目的を起点にする)

### 含まない

- `crystal:verifier` を標準フローへ復帰させること(目的 3 の常時化)
- CI の追加、`adr-lint.sh` の自動実行
- `skills/` の分離、`format-on-save.sh` / `lint-changed.sh` の削除
  (どちらも継続して同居させる)
- テストの中身や仕様の内容が妥当かの判定

## 受け入れ条件

- [x] AC-1: 実装ファイルだけが変わった Stop で、テストと spec の両方の欠落を指摘して
      exit 2 で差し戻す — 検証: `npm test` の `change-gate.sh` スイートが exit 0
- [x] AC-2: 実装・テスト・spec が揃っていれば exit 0 で素通しする
- [x] AC-3: ドキュメントのみ・設定ファイルのみ・spec のみの変更では差し戻さない
      (誤検出を出さない)
- [x] AC-4: 主要なテスト命名規約(`*.test.*` / `tests?/` / `__tests__/` / `test_*.py` /
      `*_test.go` / `*Test.java` / `conftest.py` / `spec/` / `e2e/`)をテストとして認識する
- [x] AC-5: `docs/spec/` をテストファイルと誤認しない(`specs?/` パターンとの衝突を除く)
- [x] AC-6: `stop_hook_active` の再停止では素通しする(免除を述べれば通る)
- [x] AC-7: `CRYSTAL_TEST_GATE=off` / `CRYSTAL_SPEC_GATE=off` で各判定を個別に無効化できる
- [x] AC-8: git 管理外・変更なしでは何もしない
- [x] AC-9: 削除後もリポジトリのテストが全て通る — 検証: `npm test` が exit 0
- [x] AC-10: 削除したアセットへの参照がリポジトリに残っていない —
      検証: `grep -rn "goal-gate\|eval-run\|pre-bash-guard\|log-bash\|audit-config"` が
      ドキュメント上の記録を除いて 0 件

## 制約

- テストの中身・仕様の内容が妥当かは判定しない。差分の形だけを見る
- 免除(既存テストで担保されるリファクタ / 仕様が変わらないバグ修正 / 使い捨て
  スクリプト)は機械判定できないため、1 度だけ差し戻して理由の明示に委ねる。
  `stop_hook_active` を無視して毎ターン差し戻す設計にはしない
- プロジェクト単位で無効化できること。切れないゲートは plugin ごと外される
- `format-on-save.sh` / `lint-changed.sh` / `skills/` は今回の削除対象に含めない
