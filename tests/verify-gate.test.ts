import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { runVerifyGate } from "./helpers/sandbox";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

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

    it("仕様が docs/spec/ のサブディレクトリにあっても発火する", () => {
      // SPEC_RE は docs/spec/ 配下の全 .md を仕様と認める (change-gate はサブディレクトリの
      // spec で満足する)。発火条件が直下しか見ないと、仕様を機能別ディレクトリに
      // 整理した途端このゲートだけが黙って死ぬ
      const r = runVerifyGate({
        added: {
          "src/auth.ts": "x\n",
          "docs/spec/auth/login.md": "# 仕様\n",
        },
        events: [{ edit: "src/auth.ts" }],
      });

      expect(r.exitCode).toBe(2);
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

  describe("判定が不合格なら通さない", () => {
    const FAIL = "## 判定サマリー\n満たす: 1件 / 満たさない: 1件\n\nCRYSTAL-VERDICT: FAIL AC-2, AC-5";

    it("verifier が FAIL を返したら差し戻す", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", result: FAIL }],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("独立検証が不合格です");
    });

    it("未達の条件 ID を差し戻しメッセージに載せる", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", result: FAIL }],
      });

      expect(r.stderr).toContain("AC-2, AC-5");
    });

    it("FAIL は stop_hook_active でも素通ししない", () => {
      // 直せば PASS になるので、ここで折れると不合格のまま完了できてしまう
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", result: FAIL }],
        stopHookActive: true,
      });

      expect(r.exitCode).toBe(2);
    });

    it("FAIL の detail に PASS を含む文字列があっても合格にしない", () => {
      // 合否を行全体への部分一致で見ると "FAIL AC-PASSWORD-VALIDATION" が合格扱いになる。
      // AC の ID は仕様を書いた側が命名するため、偶発的にも意図的にも踏める
      const r = runVerifyGate({
        added: REPO,
        events: [
          {
            edit: "src/auth.ts",
          },
          {
            agent: "crystal:verifier",
            result: "満たさない: 1件\n\nCRYSTAL-VERDICT: FAIL AC-PASSWORD-VALIDATION",
          },
        ],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("独立検証が不合格です");
    });

    it("散文で「満たさない」と書かれていても、判定行が PASS なら通す", () => {
      // 判定は 1 行の契約だけを見る。散文の読解に戻すと判定基準が曖昧になる
      const r = runVerifyGate({
        added: REPO,
        events: [
          { edit: "src/auth.ts" },
          {
            agent: "crystal:verifier",
            result: "満たさない: 0件 と書いてあるが紛らわしい文章\n\nCRYSTAL-VERDICT: PASS",
          },
        ],
      });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("判定行が読み取れないときは詰ませない", () => {
    // 古い verifier 定義が動いている場合に、抜けられないループを作らないこと。
    // 「最後の変更より後に検証を回した」担保は既に取れている
    const NO_VERDICT = "## 判定サマリー\n満たす: 2件 / 満たさない: 0件";

    it("判定行が無ければ 1 度差し戻す", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", result: NO_VERDICT }],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("判定行を読み取れませんでした");
      expect(r.stderr).toContain("plugin update");
    });

    it("再停止では素通しする (詰ませない)", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", result: NO_VERDICT }],
        stopHookActive: true,
      });

      expect(r.exitCode).toBe(0);
    });

    it("tool_result そのものが無い場合も同じ扱いにする", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ edit: "src/auth.ts" }, { agent: "crystal:verifier", noResult: true }],
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("判定行を読み取れませんでした");
    });
  });

  describe("verifier との契約が両側で一致している", () => {
    // hook が読む文字列と、verifier に出力させる文字列は別ファイルにある。
    // 片方だけ書き換えると、判定が黙って「読み取れません」に落ちて無力化される
    const hook = readFileSync(resolve(ROOT, "hooks/verify-gate.sh"), "utf8");
    const agent = readFileSync(resolve(ROOT, "agents/verifier.md"), "utf8");

    it("番兵の文字列が hook と verifier の定義で一致している", () => {
      expect(hook).toContain("CRYSTAL-VERDICT:");
      expect(agent).toContain("CRYSTAL-VERDICT: PASS");
      expect(agent).toContain("CRYSTAL-VERDICT: FAIL");
    });

    it("verifier の定義が出力する判定行を、hook の正規表現が実際に拾える", () => {
      const re = /^\s*CRYSTAL-VERDICT:\s*(PASS|FAIL)/;
      const lines = agent
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l.startsWith("CRYSTAL-VERDICT:"));

      expect(lines.length).toBeGreaterThan(0);
      for (const line of lines) expect(line).toMatch(re);
    });
  });

  describe("サブエージェントに委譲した実装も検証の対象にする", () => {
    // メイン transcript にはサブエージェントの編集が現れないため、実装を Task で
    // 委譲するだけでゲートが沈黙していた。record-subagent-edits.sh (SubagentStop) の
    // 記録があるときは、サブエージェント起動を「コードが変わったかもしれない」として扱う
    const SID = "sess-1";

    it("サブエージェントがコードを変更し、verifier を呼んでいなければ差し戻す", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: true,
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("サブエージェント");
    });

    it("verifier を一度も呼んでいない場合は stop_hook_active でも折れない", () => {
      // verifier を呼べば VERIFY が最後の印になって自然に抜けられる
      const r = runVerifyGate({
        added: REPO,
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: true,
        stopHookActive: true,
      });

      expect(r.exitCode).toBe(2);
    });

    it("サブエージェントの変更後に verifier が PASS すれば通し、記録を消す", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ agent: "general-purpose" }, { agent: "crystal:verifier" }],
        sessionId: SID,
        subagentEditsRecorded: true,
      });

      expect(r.exitCode).toBe(0);
      expect(r.subagentEditsRemain).toBe(false);
    });

    it("検証後のサブエージェント起動は 1 度だけ差し戻す", () => {
      // どの起動がコードを変更したかは記録から分からない。調査エージェントかも
      // しれないので、change-gate と同じく理由の明示で通す
      const r = runVerifyGate({
        added: REPO,
        events: [
          { agent: "general-purpose" },
          { agent: "crystal:verifier" },
          { agent: "Explore" },
        ],
        sessionId: SID,
        subagentEditsRecorded: true,
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("検証後にサブエージェント");
    });

    it("検証後のサブエージェント起動は、再停止では通して記録を消す", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [
          { agent: "general-purpose" },
          { agent: "crystal:verifier" },
          { agent: "Explore" },
        ],
        sessionId: SID,
        subagentEditsRecorded: true,
        stopHookActive: true,
      });

      expect(r.exitCode).toBe(0);
      expect(r.subagentEditsRemain).toBe(false);
    });

    it("verifier が FAIL のままなら、後からサブエージェントが動いていても折れない", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [
          { agent: "general-purpose" },
          {
            agent: "crystal:verifier",
            result: "CRYSTAL-VERDICT: FAIL AC-1",
          },
          { agent: "Explore" },
        ],
        sessionId: SID,
        subagentEditsRecorded: true,
        stopHookActive: true,
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("独立検証が不合格です");
    });

    it("コードを変更したサブエージェントの記録が無ければ、起動だけでは差し戻さない", () => {
      // 調査・レビュー専門のエージェントを走らせただけのターンを差し戻す誤検出を出さない
      const r = runVerifyGate({
        added: REPO,
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: false,
      });

      expect(r.exitCode).toBe(0);
    });

    it("session_id が取れないビルドでは従来どおり素通しする (fail-open)", () => {
      const r = runVerifyGate({
        added: REPO,
        events: [{ agent: "general-purpose" }],
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
