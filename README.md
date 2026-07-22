# claude-toolbox

個人用の Claude Code アセットを 1 つの plugin **`crystal`** にまとめたリポジトリ。

## 含まれるもの

| ディレクトリ | 内容 |
|---|---|
| `skills/` | 自作スキル 11 個 |
| `agents/` | `spec-critic`, `verifier` |
| `commands/` | `/learn`, `/spec` |
| `hooks/` | `hooks.json` + スクリプト 6 本(破壊コマンドガード / format-on-save / lint / bash ログ / stop-gate / audit-config) |
| `rules/` | コーディング規約・テスト方針など(参照資料) |
| `templates/` | spec / lessons テンプレート |

> 共有 skill(`bigquery-basics` などの公式/共有アセット)は本リポジトリには含めず、`~/.claude/skills` 側でシンボリックリンクとして別管理する。

## インストール(ローカル)

```bash
claude plugin marketplace add ~/claude-toolbox
claude plugin install crystal@yuki-local --scope user
```

新しいセッションで有効化される。以降:

- コマンド: `crystal:spec` / `crystal:learn`
- サブエージェント: `crystal:spec-critic` / `crystal:verifier`
- スキル 11 個は `crystal` 由来でロード
- hooks(PreToolUse/PostToolUse/Stop)が自動登録される

## 更新

リポジトリを編集したら、marketplace のキャッシュを更新する:

```bash
claude plugin marketplace update yuki-local
```

## 構成

- `.claude-plugin/plugin.json` — plugin マニフェスト(`name: crystal`)
- `.claude-plugin/marketplace.json` — ローカルマーケットプレイス定義(`name: yuki-local`)
- `hooks/hooks.json` — hooks 登録。コマンドは `${CLAUDE_PLUGIN_ROOT}/hooks/*.sh` を参照する

## 前提

- hooks は `node` / `jq` が PATH にあることを前提とする。
- `rules/` は参照資料。実際の適用は `~/.claude/CLAUDE.md` からの参照で行う。
- `audit-config.sh` は手動実行用スクリプトで、`hooks.json` には登録していない。
