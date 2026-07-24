# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個 |
| `agents/` | `spec-critic`, `verifier` |
| `commands/` | `/learn`, `/spec`, `/goal`, `/eval`, `/loop` |
| `hooks/` | `hooks.json` + スクリプト 8 本(破壊コマンドガード / format-on-save / lint / bash ログ / stop-gate / goal-gate / session-rules / audit-config) |
| `scripts/` | 手動実行系スクリプト(`eval-run.sh`, `loop-next.sh`, `loop-guard.sh`, `loop-log.sh`) |
| `rules/` | コーディング規約・テスト方針・検証ラダーなど(SessionStart hook `session-rules.sh` が全セッションに自動注入) |
| `templates/` | spec / lessons / goal / eval-case / loop / backlog テンプレート |
| `evals/` | このリポジトリ自身の eval ケース(`scripts/eval-run.sh` で実行) |

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、`~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール(ローカル)

```bash
claude plugin marketplace add ~/claude-toolbox
claude plugin install crystal@yuki-local --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn` / `crystal:goal` / `crystal:eval` / `crystal:loop`
- サブエージェント: `crystal:spec-critic` / `crystal:verifier`
- スキル 11 個は `crystal` 由来でロード
- hooks(SessionStart/PreToolUse/PostToolUse/Stop)が自動登録され、
  `rules/*.md` はセッション開始時に自動でコンテキストへ注入される

## Loop Engineering

「プロンプトを1回ずつ書く」のではなく「エージェントが回るループを設計する」ための構成。
crystal はループを **外側**(仕事を見つけて渡す)と **内側**(完了まで反復する)に分けている。

```
外側 (/crystal:loop next)  discover → 仕様 → ゴール定義 → [内側] → 独立検証 → 台帳 → 次へ
内側 (goal-gate hook)                          実装 ⇄ 達成判定 を完了条件を満たすまで反復
```

| 構成要素 | crystal での実装 |
|---|---|
| automations(周期実行) | **組み込みに委譲**。`/loop 30m /crystal:loop next` または Routines から呼ぶ |
| worktrees(並列隔離) | **組み込みに委譲**。`LOOP.md` の契約から参照するだけ |
| skills(プロジェクト知識) | `skills/` の 11 個 + `rules/` の自動注入 |
| connectors(MCP) | **既存の接続に委譲**。`/crystal:loop refill` は GitHub MCP を使う |
| subagents(独立した検証者) | `crystal:verifier`(生成者と別コンテキストで実際にコマンドを実行) |

- **ループ契約 `LOOP.md`**: トリガー / スコープ / 発見源 / 検証 / 停止条件 / ゲート の 6 節。
  `/crystal:loop init` が `templates/loop.md` から生成する
- **発見源 (discover)**: `docs/backlog.md`(1行1項目のチェックリスト)。
  `scripts/loop-next.sh` が先頭の未着手項目を 1 件だけ返す(枯渇時は exit 3)。
  GitHub Issues は `/crystal:loop refill` で backlog に取り込む
- **予算**: `LOOP.md` の `max_runs_per_day` / `max_minutes_per_run`。
  `scripts/loop-guard.sh` が実行前に判定する(トークン課金額はシェルから観測できないため、
  回数と時間で代替している)
- **台帳 (record)**: `.claude/loop/run-log.jsonl`。書き込みは必ず `scripts/loop-log.sh` 経由。
  クラッシュやコンテキストのリセットを跨いで「何を回したか」が残る
- **検証ラダー**: `rules/verification.md` に L1(決定的)〜 L5(人間)を定義。
  タスクが許す限り低いレベルに留め、検証者は生成者から独立させる

`.claude/loop/` は `.gitignore` に追加すること(`/crystal:loop init` が提案する)。

## ゴール達成自動判定 (goal-gate)

`/crystal:goal` で完了条件を `.claude/goal.md` に定義すると(`docs/spec/` に approved な
仕様があれば受け入れ条件を自動インポート)、応答完了のたびに Stop hook `goal-gate.sh` が
Haiku で達成判定し、未達なら差し戻す。

- **オプトイン**: `.claude/goal.md` が `status: active` のときだけ動く。それ以外はコストゼロ
- **毎ターン判定**: stop-gate と異なり `stop_hook_active` で素通ししない(意図的な設計差)。
  暴走防止は下記の停止条件 4 層が担う
- **停止条件は 4 層**(単独の層に頼らない):

  | 層 | 条件 | 結果 |
  |---|---|---|
  | 1. 達成 | 完了条件をすべて満たしたと判定 | `status: done` |
  | 2. 反復上限 | `round > max_rounds`(既定 5) | `status: stalled` |
  | 3. 予算 | 開始からの経過が `max_minutes`(既定 60)超 | `status: stalled` |
  | 4. 無進捗 | 差分が変わらないラウンドが `max_no_progress`(既定 2)回連続 | `status: stalled` |

  無進捗のラウンドでは判定器を呼ばずに差し戻すため、止まっている間の課金も抑えられる。
  `started_epoch` / `last_sig` は hook が自動で埋めるので手動で編集しない
- **fail-open**: claude CLI 不在・認証失敗・出力パース失敗時は判定をスキップして通す
- 判定履歴は `~/.claude/logs/goal-gate.jsonl` に残る(/learn の素材)
- `.claude/goal.md` は `.gitignore` に追加すること(untracked のままだと stop-gate の
  「変更なし判定」を汚染する)。`/crystal:goal` が追加を提案する

## Eval Engineering

プロジェクトの `evals/cases/*.md`(1ケース1ファイル、git で版管理)に検証ケースを蓄積し、
`scripts/eval-run.sh` で実行する。形式は `templates/eval-case.md` を参照。

- **command 型**: コマンド実行 + exit code / 出力正規表現で機械検証(優先)
- **rubric 型**: Haiku がルーブリックに照らして判定(主観評価のみ。CLI 不在時は SKIP)
- 操作は `/crystal:eval`(add / run / list)。FAIL が 1 件でもあれば exit 1
- `/crystal:learn` は 2 回以上再発した問題の eval ケース化を提案する
- `crystal:verifier` は `evals/` があればランナーを実行し判定材料に含める

本リポジトリ自身も `evals/cases/` を持つ(loop スクリプト・goal-gate の停止条件・
スクリプトの構文・マニフェストの JSON 妥当性)。シナリオ本体は `evals/bin/loop-cases.sh` にあり、
一時ディレクトリに最小プロジェクトを作って検証する。編集したら次を実行する:

```bash
CLAUDE_PROJECT_DIR=$(pwd) ./scripts/eval-run.sh
```

## 更新

リポジトリを編集したら、次の手順で反映する。**marketplace update だけでは
インストール済みプラグイン(キャッシュコピー)は更新されない**ことに注意:

```bash
# 1. plugin.json の version をバンプする(plugin update はバージョン番号で新旧を判定する)
# 2. marketplace のメタデータを更新
claude plugin marketplace update yuki-local
# 3. インストール済みプラグイン本体を更新
claude plugin update crystal@yuki-local
# 4. 新しいセッションを開いて反映
```

## 構成

- `.claude-plugin/plugin.json` — plugin マニフェスト(`name: crystal`)
- `.claude-plugin/marketplace.json` — ローカルマーケットプレイス定義(`name: yuki-local`)
- `hooks/hooks.json` — hooks 登録。コマンドは `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` を参照する

## 前提

- hooks は `node` / `jq` が PATH にあることを前提とする。
- goal-gate と eval の rubric 判定は `claude` CLI が PATH にあり認証済みであることを
  前提とする。満たさない場合は判定をスキップする(fail-open)。
- `rules/` は SessionStart hook が注入するため、プラグインを有効化するだけで適用される。
  外部の CLAUDE.md からの参照は不要。
- `audit-config.sh` は手動実行用スクリプトで、`hooks.json` には登録していない。
- 外側ループの周期実行(`/loop`・Routines)と worktree による並列隔離は Claude Code の
  組み込み機能に委譲している。プラグイン側にスケジューラや worktree 管理は持たない。
