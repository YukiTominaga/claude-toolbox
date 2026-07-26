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
    // 検証を主張していない調査エージェントを差し戻していた
    const innocent = [
      "テスト構成は以下の通りです。実装は未着手です。",
      "既存の lint 設定は次の通り、eslint.config.js に定義されています。",
      "build 設定の内訳は下記の通り。",
    ];
    for (const lastMessage of innocent) {
      it(`「${lastMessage.slice(0, 20)}…」は差し戻さない`, () => {
        expect(runSubagentGate({ lastMessage }).exitCode).toBe(0);
      });
    }

    it("検証に言及していない報告は差し戻さない", () => {
      const r = runSubagentGate({ lastMessage: "調査結果: 該当ファイルは 3 つでした。" });
      expect(r.exitCode).toBe(0);
    });
  });

  describe("差し戻す", () => {
    it("検証済みを主張しているのにコマンドを一度も実行していない", () => {
      const r = runSubagentGate({ lastMessage: "実装しました。テストはすべて通りました。" });
      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("完了報告の裏取りに失敗");
    });

    it("検証コマンドを文字列として含むだけのコマンドでは素通しさせない", () => {
      // 部分一致で判定していたとき、コミットメッセージ内の "npm test" で素通りしていた
      const r = runSubagentGate({
        lastMessage: "テストが通っています。",
        commands: ['git commit -m "fix: npm test が落ちる問題"', 'echo "あとで npm test を実行"'],
      });
      expect(r.exitCode).toBe(2);
    });
  });

  describe("素通しする", () => {
    it("実際に検証コマンドを実行していれば素通しする", () => {
      const r = runSubagentGate({
        lastMessage: "テストは通りました。",
        commands: ["npm test -- --run"],
      });
      expect(r.exitCode).toBe(0);
    });

    it("コマンド連結の後ろに置かれた検証コマンドも認識する", () => {
      const r = runSubagentGate({
        lastMessage: "型チェックが通りました。",
        commands: ["cd packages/api && npx tsc --noEmit"],
      });
      expect(r.exitCode).toBe(0);
    });

    it("差し戻し後の再停止 (stop_hook_active) では素通しする", () => {
      const r = runSubagentGate({
        lastMessage: "テストはすべて通りました。",
        stopHookActive: true,
      });
      expect(r.exitCode).toBe(0);
    });

    it("transcript の途中行が壊れていても後続行の実行痕跡を読み落とさない", () => {
      // jq は不正な行に当たるとその場で終了するため、実際に検証したエージェントを
      // 誤って差し戻していた
      const r = runSubagentGate({
        lastMessage: "テストは通りました。",
        commands: ["npm test"],
        corruptTranscript: true,
      });
      expect(r.exitCode).toBe(0);
    });
  });
});
