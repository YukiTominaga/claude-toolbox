---
status: active
max_runs_per_day: 8
max_minutes_per_run: 30
max_cost_usd_per_day: 5.0
issue_labels:
---
# ループ契約

## 1. トリガー (cadence)

**現在は手動のみ**。必要なときに `/crystal:loop next` を手で叩く。

昇格の条件は**その場で判定できる形**で書く。「実績ができたら」のような条件は
verifier 自身が判定できず、いつまでも昇格しないか、根拠なく昇格するかのどちらかになる。

| 段階 | 昇格に必要な条件(すべて満たすこと) |
|---|---|
| 手動 → 対話 `/loop 30m /crystal:loop next` | `.claude/loop/judge-log.jsonl` に `met:false` の行が 1 件以上ある(判定器が実際に差し戻した実績)。かつ `loop-log.sh --recent 3` が 3 件とも `done`。かつ `./scripts/loop-smoke.sh` が OK |
| 対話 → 無人 `./scripts/loop-run.sh` | 対話で 5 回連続 `done`、かつその間に人間が介入したイテレーションが 0 件。かつ `max_cost_usd_per_day` を設定済み |

無人実行の登録(cron / launchd)は**人が行う**。ループが自分でスケジュールを増やすことはしない。

## 2. 作業範囲 (bounded / unbounded)

**bounded**。この節は**触ってよいファイルの範囲**を決める。
1 イテレーションで**どこまで探索してよいか**(収束型 / 探索型)は別の軸で、
`.claude/goal.md` の完了条件の書き方で表現する(`/crystal:goal` を参照)。

- 触れてよい範囲:
  - `skills/` `agents/` `commands/` `rules/` `templates/` `scripts/` `hooks/` `evals/`
  - `README.md`
- 触れてはいけない範囲:
  - `.claude-plugin/marketplace.json`(ローカルマーケットプレイスの定義)
  - `.claude-plugin/plugin.json` の `version` 以外のフィールド
  - このリポジトリの外(`~/.claude/` 配下のユーザー環境、他リポジトリ)
  - `.git` の履歴操作(rebase / force push / タグ)

`hooks/` と `rules/` の変更は、プラグイン更新後の全セッションに影響する。
スコープ内ではあるが、変更したら必ず `evals` を通し、影響範囲を報告すること。

## 3. 発見源 (discover)

1. `docs/backlog.md` の未着手項目(先頭から 1 件)
2. GitHub Issues — `issue_labels` 未設定のため当面は使わない。
   使い始めるときはラベルを frontmatter に足して `/crystal:loop refill` を叩く

## 4. 検証 (verifier)

このリポジトリには npm / pytest のプロジェクトが無いため、自動検証は実質 `evals/` が
担っている。ここを痩せさせないこと。`.claude/checks.sh` が `project-checks.sh` から
eval スイートを呼ぶので、**crystal 自身も自分の L1 ゲートを踏む**。

| 対象 | レベル | 手段 |
|---|---|---|
| シェル / node スクリプトの構文 | L1 | `evals/cases/shell-syntax.md` |
| マニフェストと hooks.json の妥当性 | L1 | `evals/cases/json-valid.md` |
| loop スクリプトの挙動 | L1 | `evals/bin/loop-cases.sh` の各シナリオ |
| hook 単体と hook 同士の相互作用 | L1 | `evals/bin/hook-cases.sh` の各シナリオ |
| 上記すべて | L1 | `CLAUDE_PROJECT_DIR=$(pwd) ./scripts/eval-run.sh` |
| 完了条件の達成 | L4 | goal-gate (Haiku 判定) |
| Stop hook の相互作用(実 Claude Code 経由) | L3 | `./scripts/loop-smoke.sh` — **手動**。Claude Code を更新したときと Stop hook の構成を変えたときに回す |
| 下記ゲートに該当する操作 | L5 | 人間承認 |

**stalled で終わったターンのコードは未検証である**。停止条件(ラウンド上限・予算・無進捗)に
触れたラウンドでは goal-gate が L1 検証より手前で抜けるため。stalled は人間を呼ぶ状態
(L5 に上がる)なので、そこから先は人が確かめること。

スクリプトや hook の挙動を変えたら、**対応する eval ケースを同じ変更に含める**
(無ければ追加する)。eval が落ちないことだけでなく、**壊したときに落ちること**を
確認する(ミューテーションテスト)。

## 5. 停止条件 (stop rules)

- **done-check**: goal-gate が完了条件を「達成」と判定 → `status: done`
- **反復上限**: `.claude/goal.md` の `max_rounds`(既定 5)
- **予算**: 上の `max_runs_per_day: 8` / `max_minutes_per_run: 30` / `max_cost_usd_per_day: 5.0`。
  実費は無人実行 (`loop-run.sh`) でのみ観測できるので、対話セッションでは回数と時間だけが効く
- **無進捗**: 差分が変わらないラウンドが `max_no_progress`(既定 2)回続いたら `status: stalled`

## ゲート (人間承認が必要な操作)

- Pull Request の作成・マージ
- 依存関係の追加・更新、その他の破壊的な操作

`git push` は**ゲートにしない**。feature branch への追記に限りループが自分で行ってよい
(force push と履歴操作は「2. 作業範囲」で禁止済み)。理由:

- 不可逆なのは merge であって push ではない。ゲートは不可逆な側に置く
- 無人ループは承認を待てないので、**ゲートに置いた操作は実質「実行しない」と同義**になる。
  push をゲートにすると成果はローカルに留まり、使い捨てのリモート環境では
  コンテナ回収で失われる
