# Learnings

<!-- SessionStart hook (session-learnings.sh) が末尾 8000 バイトを毎セッション注入する。
     新しいエントリほど下に置くこと。1 エントリは短く保つ。 -->

## 2026-08-08: eslint は設定が無くても「実行できてしまう」

`lint-changed.sh` が eslint の起動可否を `npx --no-install eslint --version` で判定していたため、
eslint 本体が親ディレクトリや global から解決できるプロジェクトでは、設定ファイルが無くても
起動していた。eslint はその場合 "couldn't find an eslint.config.js" で非ゼロ終了するため、
hook がそれを lint 違反として報告し、`.ts` を編集するたびに偽の差し戻しが出ていた。
ツールの「実行できること」と「そのプロジェクトで使われていること」は別物として判定する。

## 2026-08-08: サブエージェントの戻り値は親の transcript に tool_result として残る

親の `transcript_path` には、`Agent`(ビルドにより `Task`)の `tool_use` と、それに
`tool_use_id` で対応する `tool_result` の両方が載る。`content` は文字列か
`[{type:"text",text:...}]` の配列のどちらか。Stop hook から「どのサブエージェントを呼び、
何を返してきたか」を後追いできる。サブエージェント起動ツールの名前は `Agent` / `Task` の
どちらにもなるため、片方だけを見る判定は書かないこと。
