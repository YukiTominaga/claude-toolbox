import { describe, expect, it } from "vitest";
import { runRecordSubagentEdits } from "./helpers/sandbox";

/**
 * record-subagent-edits.sh は「コードを変更したサブエージェントがいた」事実を
 * SubagentStop で状態ファイルに残す記録専用 hook。
 *
 * verify-gate.sh / change-gate.sh はメイン transcript しか読めず、サブエージェントの
 * 編集はそこに現れない。この記録が無いと、実装を Task に委譲するだけで
 * 独立検証の強制が丸ごと沈黙する。
 * 逆に、記録しすぎる (spec 更新や Bash のログ出力を編集扱いする) と、
 * 調査エージェントを走らせただけのターンが差し戻される誤検出になる。
 */
describe("record-subagent-edits.sh", () => {
  const SID = "sess-1";

  it("実装コードを編集したサブエージェントを記録する", () => {
    const r = runRecordSubagentEdits({ edits: ["src/auth.ts"], sessionId: SID });

    expect(r.exitCode).toBe(0);
    expect(r.recorded).toContain("src/auth.ts");
  });

  it("テストコードの編集も記録する", () => {
    const r = runRecordSubagentEdits({ edits: ["src/auth.test.ts"], sessionId: SID });

    expect(r.recorded).toContain("src/auth.test.ts");
  });

  it("ドキュメントだけを編集したサブエージェントは記録しない", () => {
    const r = runRecordSubagentEdits({ edits: ["README.md"], sessionId: SID });

    expect(r.exitCode).toBe(0);
    expect(r.recorded).toBeUndefined();
  });

  it("docs/spec/ の更新は記録しない (仕様のステータス更新で再検証を要求しない)", () => {
    const r = runRecordSubagentEdits({ edits: ["docs/spec/auth.md"], sessionId: SID });

    expect(r.recorded).toBeUndefined();
  });

  it("設定ファイルの更新は記録しない", () => {
    const r = runRecordSubagentEdits({ edits: ["vitest.config.ts"], sessionId: SID });

    expect(r.recorded).toBeUndefined();
  });

  it("Bash コマンドの実行だけでは記録しない (リダイレクトを編集扱いしない)", () => {
    const r = runRecordSubagentEdits({
      commands: ["npm test > result.log", "sed -i 's/a/b/' src/auth.ts"],
      sessionId: SID,
    });

    expect(r.recorded).toBeUndefined();
  });

  it("何も編集していないサブエージェントは記録しない", () => {
    const r = runRecordSubagentEdits({ sessionId: SID });

    expect(r.exitCode).toBe(0);
    expect(r.recorded).toBeUndefined();
  });

  it("session_id が取れなければ何もしない (fail-open)", () => {
    const r = runRecordSubagentEdits({ edits: ["src/auth.ts"] });

    expect(r.exitCode).toBe(0);
  });
});
