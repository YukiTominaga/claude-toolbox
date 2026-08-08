# 仕様: commit による全ゲート迂回を塞ぐ (commit-bypass-hardening)

- 日付: 2026-08-08
- 関連 Issue / チケット: —
- ステータス: approved

## 目的(なぜやるか)

敵対的レビューで、「強制」を名乗るゲートに実証可能な迂回経路が再び見つかった:

1. **commit すると全 Stop ゲートが沈黙する**: change-gate / verify-gate / stop-gate は
   いずれも「作業ツリーの汚れ」(HEAD との差分 + index + 未追跡) を発火条件にしていた。
   応答を終える前に `git commit` すると差分が消え、テストの対・独立検証・フルテストの
   3 つの強制が全て消える。commit はタスク完了と同義の通常運転 (リモートセッションでは
   必須) であり、「欺瞞は止めない」という保証範囲の外側 = 止めるべき側にある
2. **`BASH_WRITE_RE` の盲点**: `cp` / `mv` / `rsync` / `find -exec sed -i` /
   `xargs sed -i` / `git merge` / `git cherry-pick` によるファイル書き換えが検出されず、
   change-gate のスコープ縮小・stop-gate の作業判定・subagent-gate の変更判定が
   同時に沈黙する
3. **verifier 判定が部分一致**: `subagent_type` に `verifier` を含むだけの別エージェント
   (判定行の契約を持たない) でも VERIFY 印が立ち、「判定行が読めないときは 1 度で諦める」
   経路から抜けられる
4. **ハーネス自身の死活監視が無い**: 全 hook が fail-open かつ `jq` / `node` 前提のため、
   依存が無い環境ではプラグイン全体が無症状で死ぬ
5. **CI が無い**: ゲートの回帰テストは手動実行のみで、PR で強制されない

## スコープ

### 含む

- `record-baseline.sh` (SessionStart) がセッション開始時点の HEAD を状態ファイルに記録し、
  3 つの Stop ゲートは「ベースラインからの差分」(commit 済みの変更を含む) で判定する(1)
- ベースライン方式で差分がセッション中ずっと残ることへの対応(1 の帰結):
  - change-gate: 免除 (理由の明示) で通した指摘のダイジェストを記録し、
    同一の指摘のままの停止では再差し戻ししない
  - stop-gate: 検査が通った (または脱出口で通した) ツリー状態のダイジェストを記録し、
    同一状態のままの停止では再検査しない
- `BASH_WRITE_RE` に `cp` / `mv` / `rsync` / `truncate` / `ln` / `git merge` /
  `git cherry-pick` / `git pull` / `git rebase` / `find・xargs 経由の sed/perl -i` を追加(2)
- verifier の判定を `(^|[:/])verifier$` (名前そのもの、または接頭辞付き) に限定(3)
- `doctor.sh` (SessionStart) が `jq` / `git` / `node` の欠落を検出して警告を注入する(4)
- GitHub Actions で `npm test` + hook の構文検査を PR ごとに実行する(5)
- verify-gate の差し戻しメッセージから kill switch (`CRYSTAL_VERIFY_GATE=off`) の案内を
  除去する (監督される側に監督の外し方を教えない。案内は README = 人間向けに残す)
- `lint-changed.sh` のプロジェクトルート解決を他 hook と同じガード付きに揃える

### 含まない

- インタープリタのスクリプト実行によるファイル生成 (`python gen.py --out src/a.ts` 等) の
  検出。コマンド文字列からは書き込みの有無が判定できない (既知の残存経路として README に明記)
- エージェント自身による状態ファイル・設定 (`.claude/settings.json` の env) の改変への防御。
  従来どおり「欺瞞は止めない」の線引きの外
- ベースラインの複数リポジトリ対応 (セッションは単一のプロジェクトルートを前提とする)

## 受け入れ条件

- [x] AC-1: 実装だけを commit して停止すると change-gate が差し戻す
      — 検証: `tests/session-baseline.test.ts`
- [x] AC-2: 実装を commit して verifier を呼ばずに停止すると verify-gate が差し戻す
- [x] AC-3: 変更を commit してツリーが綺麗でも、テストが失敗していれば stop-gate が差し戻す
- [x] AC-4: ベースラインの記録が無いビルドでは従来どおり HEAD 比較で動く (fail-open)
- [x] AC-5: record-baseline.sh は既存の記録を上書きしない (resume / compact で基点が進まない)
- [x] AC-6: stop-gate は検査済みと同一のツリー状態ではテストを再実行しない。
      失敗した検査は記録されず、同一状態でも再度差し戻す
- [x] AC-7: change-gate の免除は同一の指摘にだけ効く (免除後の同一状態は素通し、
      指摘内容が変わると再び差し戻す)
- [x] AC-8: `cp` / `mv` / `rsync` / `git merge` / `git cherry-pick` /
      `find -exec sed -i` / `xargs sed -i` によるファイル書き換えが subagent-gate の
      変更判定に掛かる — 検証: `tests/subagent-gate.test.ts`
- [x] AC-9: `subagent_type` に verifier を含むだけの別エージェントでは VERIFY 印が立たない
      — 検証: `tests/verify-gate.test.ts`
- [x] AC-10: doctor.sh は依存が揃っていれば何も出力せず、欠けていれば SessionStart の
      additionalContext で警告する (jq 非依存で動く)
- [x] AC-11: 既存のテストがすべて通る — 検証: `npm test` が exit 0
- [x] AC-12: `.github/workflows/test.yml` が push / PR で `npm test` と hook の構文検査を実行する

## 制約

- ベースラインは `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/crystal/<session_id>.baseline` に
  置く。記録できない環境 (session_id 無し・git 管理外・初回コミット前) では何もせず、
  ゲートは従来どおり HEAD 比較にフォールバックする
- ダイジェストは `cksum` で取る (暗号強度は不要。依存を増やさないことを優先)
- doctor.sh は jq に依存してはいけない (jq の欠落そのものを検出するため)
