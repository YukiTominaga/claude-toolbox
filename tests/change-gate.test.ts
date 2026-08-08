import { describe, expect, it } from "vitest";
import { runChangeGate } from "./helpers/sandbox";

/**
 * change-gate.sh は「実装だけ書いてテストと仕様を書き忘れる」ことを止めるゲート。
 *
 * 検出漏れ (実装だけの変更を通す) はゲートの存在価値を失わせるが、
 * 誤検出 (ドキュメント修正のたびにテストを要求する) はゲートごと無視されるようになる。
 * どちらも静かに起きるため、両方向を明示的に押さえる。
 */
describe("change-gate.sh", () => {
  const IMPL = { "src/auth.ts": "export const login = () => true;\n" };
  const TEST = { "src/auth.test.ts": "it('works', () => {});\n" };
  const SPEC = { "docs/spec/auth.md": "# 仕様: auth\n" };

  describe("差し戻すべきケース", () => {
    it("実装だけを追加したら、テストと仕様の両方を指摘して差し戻す", () => {
      const r = runChangeGate({ added: IMPL });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("テストコードの変更がありません");
      expect(r.stderr).toContain("docs/spec/ の変更がありません");
      expect(r.stderr).toContain("src/auth.ts");
    });

    it("実装とテストがあっても、仕様が無ければ差し戻す", () => {
      const r = runChangeGate({ added: { ...IMPL, ...TEST } });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("docs/spec/ の変更がありません");
      expect(r.stderr).not.toContain("テストコードの変更がありません");
    });

    it("実装と仕様があっても、テストが無ければ差し戻す", () => {
      const r = runChangeGate({ added: { ...IMPL, ...SPEC } });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("テストコードの変更がありません");
      expect(r.stderr).not.toContain("docs/spec/ の変更がありません");
    });

    it("新規追加だけでなく、追跡済みファイルの書き換えも検出する", () => {
      // git ls-files --others だけを見ていると、既存ファイルの変更を丸ごと取りこぼす
      const r = runChangeGate({
        committed: { ...IMPL, ...TEST, ...SPEC },
        modified: { "src/auth.ts": "export const login = () => false;\n" },
      });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("テストコードの変更がありません");
    });

    it("免除の判断材料を差し戻しメッセージに含める", () => {
      // 免除 (リファクタ等) は機械判定できないため、何を書けば通るかを示す必要がある
      const r = runChangeGate({ added: IMPL });

      expect(r.stderr).toContain("免除");
      expect(r.stderr).toContain("リファクタ");
    });
  });

  describe("素通しすべきケース (誤検出を出さない)", () => {
    it("実装・テスト・仕様が揃っていれば素通しする", () => {
      const r = runChangeGate({ added: { ...IMPL, ...TEST, ...SPEC } });

      expect(r.exitCode).toBe(0);
      expect(r.stderr).toBe("");
    });

    it("ドキュメントだけの変更では何も要求しない", () => {
      const r = runChangeGate({ added: { "README.md": "# doc\n", "docs/guide.md": "x\n" } });

      expect(r.exitCode).toBe(0);
    });

    it("設定ファイルだけの変更では何も要求しない", () => {
      // .ts で終わるが実装ではないものを実装に数えると、
      // lint 設定を 1 行直すたびにテストを要求することになる
      const r = runChangeGate({
        added: {
          "vitest.config.ts": "export default {};\n",
          ".eslintrc.json": "{}\n",
          "package.json": "{}\n",
        },
      });

      expect(r.exitCode).toBe(0);
    });

    it("仕様だけを書いた段階 (実装前) では差し戻さない", () => {
      // /crystal:spec は実装前に docs/spec/ だけを作る。ここで止めると spec が書けない
      const r = runChangeGate({ added: SPEC });

      expect(r.exitCode).toBe(0);
    });

    it("変更が無ければ素通しする", () => {
      const r = runChangeGate({});

      expect(r.exitCode).toBe(0);
    });

    it("git 管理下でなければ素通しする", () => {
      const r = runChangeGate({ added: IMPL, noGit: true });

      expect(r.exitCode).toBe(0);
    });

    it("差し戻し後の再停止 (stop_hook_active) では素通しする", () => {
      const r = runChangeGate({ added: IMPL, stopHookActive: true });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("差し戻しの記録で自分の再停止だけを素通しする", () => {
    // stop_hook_active は「どれかの Stop hook が差し戻した」フラグで、自分のものとは
    // 限らない。フラグだけで素通しすると、stop-gate の差し戻しがこのゲートの検査を
    // 丸ごと免除してしまう (テストを書かないまま完了できる抜け穴になる)
    const SID = "sess-1";

    it("他のゲートが差し戻した再停止では検査を続行する", () => {
      const r = runChangeGate({ added: IMPL, stopHookActive: true, sessionId: SID });

      expect(r.exitCode).toBe(2);
    });

    it("自分が差し戻した再停止では素通しし、記録を消す", () => {
      const r = runChangeGate({
        added: IMPL,
        stopHookActive: true,
        sessionId: SID,
        ownBlockMarker: true,
      });

      expect(r.exitCode).toBe(0);
      expect(r.ownBlockMarkerRemains).toBe(false);
    });

    it("差し戻すときに自分の記録を残す", () => {
      const r = runChangeGate({ added: IMPL, sessionId: SID });

      expect(r.exitCode).toBe(2);
      expect(r.ownBlockMarkerRemains).toBe(true);
    });

    it("session_id が取れないビルドでは従来どおりチェーン全体で素通しする", () => {
      const r = runChangeGate({ added: IMPL, stopHookActive: true });

      expect(r.exitCode).toBe(0);
    });
  });

  describe("このセッションの作業痕跡で発火を絞る", () => {
    // 作業ツリーはセッション開始前から汚れていることがある (人間の書きかけ等)。
    // 会話だけのターンまで差し戻すと、ゲートは毎ターン鳴る警報になり無視される
    const SID = "sess-1";

    it("作業痕跡の無い会話だけのターンでは、ツリーが汚れていても発火しない", () => {
      const r = runChangeGate({ added: IMPL, events: [] });

      expect(r.exitCode).toBe(0);
    });

    it("セッションがドキュメントだけを編集したなら、ツリーの実装汚れでは発火しない", () => {
      const r = runChangeGate({
        added: { ...IMPL, "README.md": "# doc\n" },
        events: [{ edit: "README.md" }],
      });

      expect(r.exitCode).toBe(0);
    });

    it("セッションが実装を編集したら従来どおり対を要求する", () => {
      const r = runChangeGate({ added: IMPL, events: [{ edit: "src/auth.ts" }] });

      expect(r.exitCode).toBe(2);
    });

    it("Bash で書き換えた痕跡があれば、何を触ったか特定できないのでツリー全体を見る", () => {
      const r = runChangeGate({
        added: IMPL,
        events: [{ bash: "sed -i 's/a/b/' src/auth.ts" }],
      });

      expect(r.exitCode).toBe(2);
    });

    it("コードを変更したサブエージェントの記録があれば、ツリー全体を見る", () => {
      const r = runChangeGate({
        added: IMPL,
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: true,
      });

      expect(r.exitCode).toBe(2);
    });

    it("記録の無いサブエージェント起動 (調査のみ) では発火しない", () => {
      const r = runChangeGate({
        added: IMPL,
        events: [{ agent: "general-purpose" }],
        sessionId: SID,
        subagentEditsRecorded: false,
      });

      expect(r.exitCode).toBe(0);
    });

    it("transcript が渡らないビルドでは従来どおりツリー全体で判定する", () => {
      // fail-open で exit 0 にすると、transcript の渡し方が変わった日にゲートが黙って死ぬ
      const r = runChangeGate({ added: IMPL });

      expect(r.exitCode).toBe(2);
    });
  });

  describe("テストファイルの命名規約を取りこぼさない", () => {
    // 実装をテスト扱いに誤分類しても差し戻しが甘くなるだけだが、
    // テストをテストと認識できないと、書いたのに差し戻される最悪の誤検出になる
    const layouts: Record<string, string> = {
      "src/foo.test.ts": "同居する .test.ts",
      "src/foo.spec.js": "同居する .spec.js",
      "tests/foo.ts": "tests/ 配下",
      "test/foo.rb": "test/ 配下",
      "__tests__/foo.tsx": "__tests__/ 配下",
      "spec/foo_spec.rb": "spec/ 配下",
      "e2e/login.ts": "e2e/ 配下",
      "app/test_login.py": "test_ プレフィックス",
      "pkg/login_test.go": "_test.go サフィックス",
      "src/LoginTest.java": "Test.java サフィックス",
      "conftest.py": "pytest の conftest",
    };

    for (const [path, label] of Object.entries(layouts)) {
      it(`${label} (${path}) をテストとして認識する`, () => {
        const r = runChangeGate({ added: { ...IMPL, ...SPEC, [path]: "x\n" } });

        expect(r.exitCode).toBe(0);
      });
    }
  });

  describe("プロジェクト単位の切り替え", () => {
    // 合わないプロジェクトで切れないゲートは、plugin ごと外されて全部が失われる
    it("CRYSTAL_TEST_GATE=off でテストの指摘だけが消える", () => {
      const r = runChangeGate({ added: IMPL, env: { CRYSTAL_TEST_GATE: "off" } });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).not.toContain("テストコードの変更がありません");
      expect(r.stderr).toContain("docs/spec/ の変更がありません");
    });

    it("CRYSTAL_SPEC_GATE=off で仕様の指摘だけが消える", () => {
      const r = runChangeGate({ added: IMPL, env: { CRYSTAL_SPEC_GATE: "off" } });

      expect(r.exitCode).toBe(2);
      expect(r.stderr).toContain("テストコードの変更がありません");
      expect(r.stderr).not.toContain("docs/spec/ の変更がありません");
    });

    it("両方 off なら差し戻さない", () => {
      const r = runChangeGate({
        added: IMPL,
        env: { CRYSTAL_TEST_GATE: "off", CRYSTAL_SPEC_GATE: "off" },
      });

      expect(r.exitCode).toBe(0);
    });
  });
});
