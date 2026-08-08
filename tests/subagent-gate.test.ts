import { describe, expect, it } from "vitest";
import { runSubagentGate } from "./helpers/sandbox";

/**
 * subagent-gate.sh は「検証済みだと主張しているのに実行痕跡が無い」ときだけ差し戻す。
 * 誤検知 (調査エージェントを差し戻す) と見逃し (文字列一致だけで素通しする) の
 * どちらも静かに起きるため、その境界をテストする。
 */
describe("subagent-gate.sh", () => {
  describe("誤検知しない", () => {
    // 裸の「通り」で判定していたとき、「以下の通り」に一致して
    // 検証を主張していない調査エージェントを差し戻していた。
    // edits を必ず渡すこと: 渡さないと変更痕跡ゲートで先に exit 0 になり、
    // CLAIM_RE が壊れても緑のままになる (トートロジー化する)
    const innocent = [
      "テスト構成は以下の通りです。実装は未着手です。",
      "既存の lint 設定は次の通り、eslint.config.js に定義されています。",
      "build 設定の内訳は下記の通り。",
    ];
    for (const lastMessage of innocent) {
      it(`「${lastMessage.slice(0, 20)}…」は差し戻さない`, () => {
        expect(runSubagentGate({ lastMessage, edits: ["src/foo.ts"] }).exitCode).toBe(0);
      });
    }

    it("検証に言及していない報告は差し戻さない", () => {
      const r = runSubagentGate({
        lastMessage: "調査結果: 該当ファイルは 3 つでした。",
        edits: ["src/foo.ts"],
      });
      expect(r.exitCode).toBe(0);
    });

    // CLAIM_RE は一人称の完了報告と、他人のコードについての説明文を区別できない。
    // 調査エージェントに検証ゲートそのものを読ませると確実に一致するため、
    // 「何も変更していないエージェントは対象外」で切り分けている
    it("ファイルを変更していないエージェントの、検証に言及する説明は差し戻さない", () => {
      const r = runSubagentGate({
        lastMessage:
          "stop-gate.sh は変更があればテスト・型チェック・lint を実行し、" +
          "すべて通っていれば exit 0 で素通しします。",
      });
      expect(r.exitCode).toBe(0);
    });
  });

  describe("差し戻す", () => {
    it("検証済みを主張しているのにコマンドを一度も実行していない", () => {
      const r = runSubagentGate({
        lastMessage: "実装しました。テストはすべて通りました。",
        edits: ["src/foo.ts"],
      });
      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("完了報告の裏取りに失敗");
    });

    it("検証コマンドを文字列として含むだけのコマンドでは素通しさせない", () => {
      // 部分一致で判定していたとき、コミットメッセージ内の "npm test" で素通りしていた
      const r = runSubagentGate({
        lastMessage: "テストが通っています。",
        edits: ["src/foo.ts"],
        commands: ['git commit -m "fix: npm test が落ちる問題"', 'echo "あとで npm test を実行"'],
      });
      expect(r.exitCode).toBe(2);
    });

    it("同じ説明文でも、ファイルを変更していれば裏取りの対象になる", () => {
      // 「変更していないなら対象外」で緩めすぎていないことの担保
      const r = runSubagentGate({
        lastMessage:
          "stop-gate.sh は変更があればテスト・型チェック・lint を実行し、" +
          "すべて通っていれば exit 0 で素通しします。",
        edits: ["hooks/stop-gate.sh"],
      });
      expect(r.exitCode).toBe(2);
    });

    // Write だけを見ていると、編集ツールを使わずに書き換えたエージェントを取りこぼす
    for (const [label, command] of [
      ["sed -i", "sed -i '' 's/a/b/' src/foo.ts"],
      ["リダイレクト", 'echo "x" > src/foo.ts'],
      ["tee", 'echo "x" | tee src/foo.ts'],
      ["git apply", "git apply /tmp/p.patch"],
    ] as const) {
      it(`Bash の ${label} でファイルを書き換えた場合も裏取りの対象になる`, () => {
        const r = runSubagentGate({
          lastMessage: "修正しました。テストは通りました。",
          commands: [command],
        });
        expect(r.exitCode).toBe(2);
      });
    }

    for (const toolName of ["Edit", "MultiEdit"] as const) {
      it(`${toolName} での変更も裏取りの対象になる`, () => {
        const r = runSubagentGate({
          lastMessage: "修正しました。テストは通りました。",
          editTool: toolName,
          edits: ["src/foo.ts"],
        });
        expect(r.exitCode).toBe(2);
      });
    }
  });

  describe("素通しする", () => {
    it("実際に検証コマンドを実行していれば素通しする", () => {
      const r = runSubagentGate({
        lastMessage: "テストは通りました。",
        edits: ["src/foo.ts"],
        commands: ["npm test -- --run"],
      });
      expect(r.exitCode).toBe(0);
    });

    // Python 系はランナー経由の実行が標準的。プレフィックスを認めないと、
    // 正当に検証したエージェントを差し戻す誤検知になる
    for (const command of [
      "uv run pytest -q",
      "poetry run pytest",
      "pipenv run pytest tests/",
      "python -m pytest -q",
      "python3 -m mypy src/",
      "uv run ruff check .",
    ] as const) {
      it(`ランナー経由の検証 (${command}) も認識する`, () => {
        const r = runSubagentGate({
          lastMessage: "テストは通りました。",
          edits: ["src/foo.py"],
          commands: [command],
        });
        expect(r.exitCode).toBe(0);
      });
    }

    it("ランナープレフィックスだけでは素通しさせない", () => {
      // uv run の後続が検証コマンドでなければ、検証の実行痕跡にはならない
      const r = runSubagentGate({
        lastMessage: "テストは通りました。",
        edits: ["src/foo.py"],
        commands: ["uv run scripts/migrate.py", "python -m http.server"],
      });
      expect(r.exitCode).toBe(2);
    });

    it("コマンド連結の後ろに置かれた検証コマンドも認識する", () => {
      const r = runSubagentGate({
        lastMessage: "型チェックが通りました。",
        edits: ["src/foo.ts"],
        commands: ["cd packages/api && npx tsc --noEmit"],
      });
      expect(r.exitCode).toBe(0);
    });

    it("差し戻し後の再停止 (stop_hook_active) では素通しする", () => {
      const r = runSubagentGate({
        lastMessage: "テストはすべて通りました。",
        edits: ["src/foo.ts"],
        stopHookActive: true,
      });
      expect(r.exitCode).toBe(0);
    });

    it("transcript の途中行が壊れていても後続行の実行痕跡を読み落とさない", () => {
      // jq は不正な行に当たるとその場で終了するため、実際に検証したエージェントを
      // 誤って差し戻していた
      const r = runSubagentGate({
        lastMessage: "テストは通りました。",
        edits: ["src/foo.ts"],
        commands: ["npm test"],
        corruptTranscript: true,
      });
      expect(r.exitCode).toBe(0);
    });
  });
});
