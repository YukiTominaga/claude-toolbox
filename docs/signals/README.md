# signals — 未処理の発見の置き場

ループが仕事の途中で気づいたこと(摩擦・取りこぼし・壊れている前提)を 1 件 1 ファイルで
残す場所。**それ単体では着手できないもの**を置く。誰かが backlog に昇格させて初めて仕事になる。

追記は `scripts/signal-add.sh` を使う。**ファイルを手で書かない**(採番はスクリプトが行う)。

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/signal-add.sh" "<一行タイトル>" "<出どころ>" "<本文>"
```

## 何を入れる

- verifier が「満たさない」と判定し、その原因が**いま扱っている項目の外**にあるもの
- goal が `stalled` で終わったときの理由
- `blocked` / `failed` で終わったイテレーションで、次に効く情報
- 作業中に見つかった、別の場所の壊れている前提

## 何を入れない

- **やること**(→ `docs/backlog.md`。`loop-add.sh` で積む)
- **確定した再利用可能な知見**(→ `.claude/learnings.md`。`/crystal:learn` が書く)
- **何を回したかの履歴**(→ `.claude/loop/run-log.jsonl`。`loop-log.sh` が書く)
- 秘密情報(パス・トークン・認証情報)

## スキーマ

```markdown
---
id: S-3
created: 2026-07-25
source: Q-7 / verifier      # 出どころ。空でもよい
status: open                # open | converted | dropped | learned
---
# 一行タイトル

本文。何に気づいたか、なぜ効くか、次に何を確かめるか。
```

`status` の遷移:

| 値 | 意味 |
|---|---|
| `open` | 未処理。`/crystal:loop next` がキュー枯渇時に昇格候補として提示する |
| `converted` | `docs/backlog.md` に昇格した(仕事になった) |
| `learned` | `.claude/learnings.md` に知見として書き出した(再発防止が済んだ) |
| `dropped` | 見送った。理由を本文に追記する |

## 記録先の使い分け

| ストア | 答える問い | 書く | 読む | git |
|---|---|---|---|---|
| `docs/backlog.md` | 何を、どの順でやるか | `loop-add.sh` | `loop-next.sh` | ✓ |
| `docs/signals/` | 何に気づいたか(未処理) | `signal-add.sh` | `loop next`(枯渇時)、`/crystal:learn` | ✓ |
| `.claude/learnings.md` | 確定した再利用可能な知見 | `/crystal:learn` | 人・将来のセッション | ✓ |
| `.claude/loop/run-log.jsonl` | 何を回したか(実行の事実) | `loop-guard.sh` / `loop-log.sh` | `loop next` の冒頭 | ✗ ローカル |

signals と learnings は重複ではなく**ライフサイクルの段階が違う**
(`docs/backlog.md` と `docs/spec/` の使い分けと同じ構造)。
signal は「未処理の発見」、learnings は「処理を終えて再利用可能になった知見」。
