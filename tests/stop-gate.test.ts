import { describe, expect, it } from "vitest";
import { runStopGate } from "./helpers/sandbox";

/**
 * stop-gate.sh は「完了と報告する前に実際の検証を通す」ためのゲート。
 * 誤って差し戻す (正しいテストを失敗と誤判定する) のも、
 * 黙って素通しする (検証したつもりで検証していない) のも、どちらも静かに起きる。
 */
describe("stop-gate.sh", () => {
  it("argv を検査する test スクリプトを誤って失敗と判定しない", () => {
    // `npm test -- --silent` は --silent を test スクリプトの argv に注入するため、
    // 未知の引数を拒否するランナーでは成功しているテストが失敗扱いになっていた
    const strict = [
      "node -e \"if (process.argv.slice(1).length) { console.error('EXTRA ARGV'); process.exit(1) }\"",
    ].join("");

    const r = runStopGate({ testScript: strict });

    expect(r.exitCode).toBe(0);
  });

  it("テストが失敗していれば差し戻す", () => {
    const r = runStopGate({ testScript: "exit 1" });

    expect(r.exitCode).toBe(2);
    expect(r.stderr).toContain("検証ゲート失敗");
  });

  it("差し戻し後の再停止 (stop_hook_active) では素通しする", () => {
    const r = runStopGate({ testScript: "exit 1", stopHookActive: true });

    expect(r.exitCode).toBe(0);
  });

  describe("差し戻しの記録で自分の再停止だけを素通しする", () => {
    // stop_hook_active は「どれかの Stop hook が差し戻した」フラグ。フラグだけで
    // 素通しすると、change-gate の差し戻し後に追加された壊れたテストを
    // 一度も実行しないまま完了できてしまう
    const SID = "sess-1";

    it("他のゲートが差し戻した再停止では検証を実行する", () => {
      const r = runStopGate({ testScript: "exit 1", stopHookActive: true, sessionId: SID });

      expect(r.exitCode).toBe(2);
    });

    it("自分が差し戻した再停止では素通しする (詰まないための脱出口)", () => {
      const r = runStopGate({
        testScript: "exit 1",
        stopHookActive: true,
        sessionId: SID,
        ownBlockMarker: true,
      });

      expect(r.exitCode).toBe(0);
    });

    it("session_id が取れないビルドでは従来どおりチェーン全体で素通しする", () => {
      const r = runStopGate({ testScript: "exit 1", stopHookActive: true });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("このセッションの作業痕跡で発火を絞る", () => {
    const SID = "sess-1";

    it("作業痕跡の無い会話だけのターンでは、ツリーが汚れていても検証を回さない", () => {
      const r = runStopGate({ testScript: "exit 1", events: [] });

      expect(r.exitCode).toBe(0);
    });

    it("編集ツールの痕跡があれば検証を回す", () => {
      const r = runStopGate({ testScript: "exit 1", events: [{ edit: "src/a.ts" }] });

      expect(r.exitCode).toBe(2);
    });

    it("Bash で書き換えた痕跡があれば検証を回す", () => {
      const r = runStopGate({
        testScript: "exit 1",
        events: [{ bash: "sed -i 's/a/b/' src/a.ts" }],
      });

      expect(r.exitCode).toBe(2);
    });

    it("コードを変更したサブエージェントの記録があれば検証を回す", () => {
      const r = runStopGate({
        testScript: "exit 1",
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: true,
      });

      expect(r.exitCode).toBe(2);
    });

    it("記録の無いサブエージェント起動 (調査のみ) では検証を回さない", () => {
      const r = runStopGate({
        testScript: "exit 1",
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: false,
      });

      expect(r.exitCode).toBe(0);
    });

    it("transcript が渡らないビルドでは従来どおり検証を回す", () => {
      const r = runStopGate({ testScript: "exit 1" });

      expect(r.exitCode).toBe(2);
    });
  });
});
