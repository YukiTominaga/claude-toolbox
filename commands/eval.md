---
description: プロジェクトの eval セット (evals/) を管理・実行する
---

# /eval — Eval Engineering

プロジェクトの `evals/cases/*.md` (1ケース1ファイル、git で版管理) を管理・実行する。
ケース形式は `${CLAUDE_PLUGIN_ROOT}/templates/eval-case.md` を参照。type は 2 種類:

- **command 型**: コマンド実行 + exit code / 出力の正規表現で機械的に検証。
  コマンドで検証できるものは必ずこちらを優先する
- **rubric 型**: LLM (Haiku) がルーブリックに照らして判定。主観評価が必要なもののみ

`$ARGUMENTS` に応じて分岐すること:

## `add` の場合

1. 会話から題材を聞き取り、何を二度と壊したくないのか・何を保証したいのかを特定する
2. command 型で書けないか最初に検討する。書けない場合のみ rubric 型にする
3. `${CLAUDE_PLUGIN_ROOT}/templates/eval-case.md` の該当形式に沿って `evals/cases/<id>.md` を作成する
   (id はケース内容を表す kebab-case。ディレクトリがなければ作成)
4. 作成後、`"${CLAUDE_PLUGIN_ROOT}/scripts/eval-run.sh" <id>` で 1 回実行して動作を確認する
   (ランナーはプラグイン側にしか無い。プロジェクト相対パスでは解決できない)
5. evals/ は再発防止の資産なので、git commit をユーザーに提案する

## `run [id...]` の場合

1. Bash で `"${CLAUDE_PLUGIN_ROOT}/scripts/eval-run.sh" <id...>` を実行する
   (id 省略時は全ケース)
2. 結果表(PASS/FAIL/SKIP)とサマリーを報告する
3. FAIL があれば、各ケースの理由を踏まえた修正方針を提示する。勝手に修正しない
4. SKIP (claude CLI 不在等) があれば、その旨と解消方法を明示する

## `list` の場合

`evals/cases/*.md` の id / type / description を一覧表示する。
ディレクトリがなければ「eval セットは未作成。/crystal:eval add で作成できる」と案内する。

## 引数なしの場合

サブコマンド(add / run / list)の案内と、現在の evals/ の概況(ケース数・型の内訳)を
表示する。

$ARGUMENTS
