import { describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  runChangeGate,
  runDoctor,
  runRecordBaseline,
  runStopGate,
  runVerifyGate,
} from "./helpers/sandbox";

/**
 * 敵対的レビューで実証された最重要の迂回経路:
 * ゲートの比較基点が常に HEAD だったため、応答を終える前に git commit するだけで
 * 差分が消え、change-gate / verify-gate / stop-gate の 3 つ全てが沈黙していた。
 * commit はタスク完了と同義の通常運転 (リモートセッションでは必須) であり、
 * 「欺瞞は止めない」という保証範囲の外側 = 止めるべき側にある。
 *
 * 対策: record-baseline.sh (SessionStart) がセッション開始時点の HEAD を記録し、
 * 各ゲートは「ベースラインからの差分」(commit 済みの変更を含む) で判定する。
 */
describe("commit しても Stop ゲートが沈黙しない (session baseline)", () => {
  const SID = "sess-1";
  const IMPL = { "src/auth.ts": "export const login = () => true;\n" };
  const TEST = { "src/auth.test.ts": "it('works', () => {});\n" };
  const SPEC = { "docs/spec/auth.md": "# 仕様: auth\n" };

  describe("record-baseline.sh", () => {
    it("セッション開始時点の HEAD を記録する", () => {
      const r = runRecordBaseline({ sessionId: SID });

      expect(r.exitCode).toBe(0);
      expect(r.baseline).toBe(r.head);
    });

    it("既存の記録を上書きしない (resume で基点が進むと commit 済み変更が漏れる)", () => {
      const r = runRecordBaseline({ sessionId: SID, existingBaseline: "deadbeef" });

      expect(r.exitCode).toBe(0);
      expect(r.baseline).toBe("deadbeef");
    });

    it("session_id が取れないビルドでは何もしない (fail-open)", () => {
      const r = runRecordBaseline({});

      expect(r.exitCode).toBe(0);
    });

    it("git 管理下でなければ何もしない", () => {
      const r = runRecordBaseline({ sessionId: SID, noGit: true });

      expect(r.exitCode).toBe(0);
      expect(r.baseline).toBeUndefined();
    });
  });

  describe("change-gate: commit 済みの変更も対を要求する", () => {
    it("実装だけを commit して停止したら差し戻す", () => {
      const r = runChangeGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: IMPL,
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("テストコードの変更がありません");
    });

    it("実装・テスト・仕様が揃った commit なら素通しする", () => {
      const r = runChangeGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: { ...IMPL, ...TEST, ...SPEC },
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(0);
    });

    it("ベースラインの記録が無いビルドでは従来どおり HEAD 比較 (fail-open)", () => {
      const r = runChangeGate({
        sessionId: SID,
        committedInSession: IMPL,
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("verify-gate: commit 済みの実装も独立検証の対象にする", () => {
    it("実装を commit して verifier を呼ばずに停止したら差し戻す", () => {
      const r = runVerifyGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: { ...IMPL, ...SPEC },
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("独立検証が済んでいません");
    });

    it("verifier が最後なら commit 済みでも素通しする", () => {
      const r = runVerifyGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: { ...IMPL, ...SPEC },
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier" }],
      });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("stop-gate: commit 済みでも検証を回す", () => {
    it("変更を commit してツリーが綺麗でも、テストが失敗していれば差し戻す", () => {
      const r = runStopGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: IMPL,
        dirty: false,
        testScript: "exit 1",
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("検証ゲート失敗");
    });

    it("ベースラインの記録が無いビルドでは従来どおり素通しする (fail-open)", () => {
      const r = runStopGate({
        sessionId: SID,
        committedInSession: IMPL,
        dirty: false,
        testScript: "exit 1",
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("stop-gate: 検査済みの同一状態では再検査しない", () => {
    // ベースライン方式では検証済みの変更がセッション中ずっと差分として残る。
    // 状態のダイジェストで判定しないと、検証後の会話だけのターンでも毎回
    // フルテストが走り、待ち時間が積み上がってゲートごと無視される
    it("同一状態での 2 回目の停止ではテストを再実行しない", () => {
      const dir = mkdtempSync(join(tmpdir(), "stop-counter-"));
      const counter = join(dir, "runs.txt");
      writeFileSync(counter, "");
      try {
        const r = runStopGate({
          sessionId: SID,
          baselineRecorded: true,
          committedInSession: { "src/a.ts": "x\n" },
          dirty: false,
          testScript: 'echo x >> "$COUNTER"',
          events: [{ edit: "src/a.ts" }],
          env: { COUNTER: counter },
          repeat: 2,
        });

        expect(r.exitCodes).toEqual([0, 0]);
        const runs = readFileSync(counter, "utf8").split("\n").filter(Boolean).length;
        expect(runs).toBe(1);
      } finally {
        rmSync(dir, { recursive: true, force: true });
      }
    });

    it("失敗した検査は記録されず、同一状態でも再度差し戻す", () => {
      const r = runStopGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: { "src/a.ts": "x\n" },
        dirty: false,
        testScript: "exit 1",
        events: [{ edit: "src/a.ts" }],
        repeat: 2,
      });

      expect(r.exitCodes).toEqual([2, 2]);
    });
  });

  describe("change-gate: 免除は同一の指摘にだけ効く", () => {
    // ベースライン方式では免除済みの差分がセッション中ずっと changed に残る。
    // 免除 (理由の明示) の後、同じ指摘のままの停止で毎ターン差し戻すと
    // ゲートごと無視される。一方で免除の記録が別の変更まで覆ってはいけない
    it("免除で通した後、同じ状態の次の停止では差し戻さない", () => {
      const r = runChangeGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: IMPL,
        events: [{ edit: "src/auth.ts" }],
        // 1 回目: 差し戻し / 2 回目: 再停止で免除 (理由の明示) / 3 回目: 通常の停止
        runs: [{ stopHookActive: false }, { stopHookActive: true }, { stopHookActive: false }],
      });

      expect(r.exitCodes).toEqual([2, 0, 0]);
    });

    it("古い免除記録は現在の指摘と一致しなければ効かない", () => {
      const r = runChangeGate({
        sessionId: SID,
        baselineRecorded: true,
        committedInSession: IMPL,
        events: [{ edit: "src/auth.ts" }],
        excusedDigest: "stale-digest",
      });

      expect(r.exitCode).toBe(2);
    });
  });

  describe("doctor.sh: ハーネスの死活を報告する", () => {
    it("依存が揃っていれば何も出力しない", () => {
      const r = runDoctor();

      expect(r.exitCode).toBe(0);
      expect(r.stdout).toBe("");
    });

    it("依存が欠けていれば警告をコンテキストに注入する", () => {
      // PATH を空にして jq / git / node が全て見えない環境を再現する
      const r = runDoctor("");

      expect(r.exitCode).toBe(0);
      const out = JSON.parse(r.stdout);
      expect(out.hookSpecificOutput.hookEventName).toBe("SessionStart");
      expect(out.hookSpecificOutput.additionalContext).toContain("jq");
      expect(out.hookSpecificOutput.additionalContext).toContain("fail-open");
    });
  });
});
