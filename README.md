# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個 |
| `agents/` | `spec-critic`, `verifier` |
| `commands/` | `/learn`, `/spec`, `/goal`, `/eval` |
| `hooks/` | `hooks.json` + スクリプト 8 本(破壊コマンドガード / format-on-save / lint / bash ログ / stop-gate / goal-gate / session-rules / audit-config) |
| `scripts/` | 手動実行系スクリプト(`eval-run.sh`) |
| `rules/` | コーディング規約・テスト方針など(SessionStart hook `session-rules.sh` が全セッションに自動注入) |
| `templates/` | spec / lessons / goal / eval-case テンプレート |

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、`~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール(ローカル)

```bash
claude plugin marketplace add ~/claude-toolbox
claude plugin install crystal@yuki-local --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn` / `crystal:goal` / `crystal:eval`
- サブエージェント: `crystal:spec-critic` / `crystal:verifier`
- スキル 11 個は `crystal` 由来でロード
- hooks(SessionStart/PreToolUse/PostToolUse/Stop)が自動登録され、
  `rules/*.md` はセッション開始時に自動でコンテキストへ注入される

## ゴール達成自動判定 (goal-gate)

`/crystal:goal` で完了条件を `.claude/goal.md` に定義すると(`docs/spec/` に approved な
仕様があれば受け入れ条件を自動インポート)、応答完了のたびに Stop hook `goal-gate.sh` が
Haiku で達成判定し、未達なら差し戻す。

- **オプトイン**: `.claude/goal.md` が `status: active` のときだけ動く。それ以外はコストゼロ
- **毎ターン判定**: stop-gate と異なり `stop_hook_active` で素通ししない(意図的な設計差)。
  無限ループ防止は round カウンタ + `max_rounds`(既定 5、超過で `status: stalled`)が担う
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
