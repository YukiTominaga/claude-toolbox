# 仕様: subagent-gate がランナー経由の検証コマンドを認識する

- 日付: 2026-08-08
- 関連 Issue / チケット: PR #15 の「含めないもの」からの追い掛け
- ステータス: approved

## 目的(なぜやるか)

`subagent-gate.sh` の検証コマンド判定 (`VERIFY_CMD`) はコマンド先頭のツール名しか
見ておらず、Python 系で標準的なランナー経由の実行 (`uv run pytest` /
`poetry run pytest` / `python -m pytest`) を検証の実行痕跡として認識しない。
このままでは、正当に検証した Python 系サブエージェントの完了報告が
「実行痕跡なし」として差し戻される誤検知になる。誤検知するゲートは
最終的に丸ごと無視される。

## スコープ

### 含む

- `VERIFY_SEP` と `VERIFY_CMD` の間に、任意のランナープレフィックス
  (`uv run` / `poetry run` / `pipenv run` / `python -m` / `python3 -m`) を認める

### 含まない

- ランナープレフィックス単体を検証痕跡と認めること (後続に検証コマンドが要る)
- Node 系ランナーの追加 (`npx` は既に対応済み)
- `VERIFY_CMD` のツール一覧そのものの拡張

## 受け入れ条件

- [x] AC-1: `uv run pytest` / `poetry run pytest` / `pipenv run pytest` /
      `python -m pytest` / `python3 -m mypy` / `uv run ruff check` を
      検証の実行痕跡として認識する — 検証: `npm test` の subagent-gate スイートが exit 0
- [x] AC-2: ランナープレフィックスの後続が検証コマンドでなければ従来どおり差し戻す
      (`uv run scripts/migrate.py` は痕跡にならない)
- [x] AC-3: 既存の判定 (先頭一致・部分一致の拒否) が変わらない — 検証: 既存テストが全て通る

## 制約

- 判定はこれまでどおりコマンド先頭 (または `;` `&&` `||` `|` `(` の直後) からの
  一致に限る。部分一致に緩めない
