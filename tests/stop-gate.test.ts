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

  it("ゴールが active の間は stop_hook_active でも素通ししない", () => {
    // goal-gate は stop_hook_active を無視して毎ターン差し戻すため、
    // ここで素通しするとゴールループ中は実検証が一度も走らなくなる
    const r = runStopGate({
      testScript: "exit 1",
      goalStatus: "active",
      stopHookActive: true,
    });

    expect(r.exitCode).toBe(2);
  });

  it("完了条件に検証コマンドがあっても、ゴールが active なら素通ししない", () => {
    // goal-gate が実際に実行するのは「## 完了条件」内かつ許可パターンに一致した
    // コマンドだけ。その条件を stop-gate 側で再現しようとすると両者がずれ、
    // どちらも実検証しないゴール(例: 許可パターン外の `flutter test`)が生まれる
    const r = runStopGate({
      testScript: "exit 1",
      goalStatus: "active",
      goalVerifyCmd: "flutter test",
      stopHookActive: true,
    });

    expect(r.exitCode).toBe(2);
  });

  it("ゴールが無ければ stop_hook_active で素通しする", () => {
    const r = runStopGate({ testScript: "exit 1", stopHookActive: true });

    expect(r.exitCode).toBe(0);
  });

  it("ゴールが done なら stop_hook_active で素通しする", () => {
    const r = runStopGate({
      testScript: "exit 1",
      goalStatus: "done",
      stopHookActive: true,
    });

    expect(r.exitCode).toBe(0);
  });
});
