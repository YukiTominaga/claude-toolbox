import { describe, expect, it } from "vitest";
import { runVerifyGate } from "./helpers/sandbox";

/**
 * verify-gate.sh は「実装しておいて独立検証を通さずに終える」ことを止めるゲート。
 *
 * 検出漏れ (検証せずに終えられる) はゲートの存在価値を失わせる。
 * 一方、抜けられないループ (検証しても差し戻され続ける) を作ると、
 * ランタイムのブロック上限まで無駄なターンを焼いたうえで plugin ごと外される。
 * 「差し戻したら verifier を呼ぶだけで必ず抜けられる」ことを明示的に押さえる。
 */
describe("verify-gate.sh", () => {
  const REPO = {
    "src/auth.ts": "export const login = () => true;\n",
    "docs/spec/auth.md": "# 仕様: auth\n\n## 受け入れ条件\n\n- [ ] AC-1: ログインできる\n",
  };

  describe("差し戻すべきケース", () => {
    it("実装を変更したまま verifier を呼んでいなければ差し戻す", () => {
      const r = runVerifyGate({ added: REPO, events: [{ edit: "src/auth.ts" }] });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("独立検証が済んでいません");
      expect(r.stderr).toContain("crystal:verifier");
      expect(r.stderr).toContain("src/auth.ts");
    });

    it("検証した後にコードを変更したら、再検証を要求する", () => {
      // 「一度でも呼んだか」で判定すると、verifier が指摘した箇所を直した後の
      // 状態が検証されないまま完了できてしまう
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier" }, { edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(2);
    });

    it("verifier 以外のサブエージェントでは通らない", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:spec-critic" }],
      });

      expect(r.exitCode).toBe(2);
    });

    it("テストコードの変更も検証を無効にする", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [
          { edit: "src/auth.ts" },
          { agent: "crystal:verifier" },
          { edit: "src/auth.test.ts" },
        ],
      });

      expect(r.exitCode).toBe(2);
    });
  });

  describe("素通しすべきケース", () => {
    it("最後の変更より後に verifier を呼んでいれば素通しする", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier" }],
      });

      expect(r.exitCode).toBe(0);
      expect(r.stderr).toBe("");
    });

    it("検証後の docs/spec/ 更新では再検証を要求しない", () => {
      // 仕様のステータスを approved → done にするだけで差し戻されると、
      // 「検証 → 仕様更新 → 差し戻し → 検証 → …」で抜けられなくなる
      const r = runVerifyGate({
        added: REPO,
        events: [
          { edit: "src/auth.ts" },
          { agent: "crystal:verifier" },
          { edit: "docs/spec/auth.md" },
        ],
      });

      expect(r.exitCode).toBe(0);
    });

    it("検証後の設定ファイル更新では再検証を要求しない", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [
          { edit: "src/auth.ts" },
          { agent: "crystal:verifier" },
          { edit: "vitest.config.ts" },
        ],
      });

      expect(r.exitCode).toBe(0);
    });

    it("docs/spec/ が無ければ発火しない", () => {
      // 仕様が無い状態で verifier を呼んでも「検証不能」しか返らず、
      // 差し戻しても状況が変わらない = 抜けられないループになる
      const r = runVerifyGate({
        added: { "src/auth.ts": "x\n" },
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(0);
    });

    it("実装の変更が無ければ発火しない", () => {
      const r = runVerifyGate({
        added: { "README.md": "# doc\n", "docs/spec/auth.md": "# 仕様\n" },
        events: [{ edit: "README.md" }],
      });

      expect(r.exitCode).toBe(0);
    });

    it("このセッションが何も編集していなければ素通しする", () => {
      // 作業ツリーが元から汚れているだけのセッションを差し戻さない
      const r = runVerifyGate({ added: REPO, events: [] });

      expect(r.exitCode).toBe(0);
    });

    it("transcript が無ければ素通しする (fail-open)", () => {
      const r = runVerifyGate({ added: REPO, noTranscript: true });

      expect(r.exitCode).toBe(0);
    });

    it("git 管理下でなければ素通しする", () => {
      const r = runVerifyGate({ added: REPO, events: [{ edit: "src/auth.ts" }], noGit: true });

      expect(r.exitCode).toBe(0);
    });

    it("CRYSTAL_VERIFY_GATE=off で無効化できる", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }],
        env: { CRYSTAL_VERIFY_GATE: "off" },
      });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("環境差とデータ破損に耐える", () => {
    it("サブエージェント起動ツールが Task 名でも認識する", () => {
      // ツール名は Claude Code のビルドによって Agent / Task のどちらにもなる。
      // 片方だけを見ているとある日静かにゲートが無効化される
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", tool: "Task" }],
      });

      expect(r.exitCode).toBe(0);
    });

    it("プラグイン接頭辞なしの verifier も認識する", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "verifier" }],
      });

      expect(r.exitCode).toBe(0);
    });

    it("Write / MultiEdit による変更も変更として数える", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts", tool: "Write" }],
      });

      expect(r.exitCode).toBe(2);
    });

    it("JSONL に壊れた行が混ざっていても判定を続ける", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier" }],
        corruptTranscript: true,
      });

      expect(r.exitCode).toBe(0);
    });
  });
});
