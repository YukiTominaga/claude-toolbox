import { describe, expect, it } from "vitest";
import { runSessionLearnings } from "./helpers/sandbox";

/**
 * .claude/learnings.md は書き溜められる一方で読み込む導線が無く、
 * 次のセッションで参照されないままだった。この hook がその回収経路。
 * 際限なく増えるファイルを丸ごと注入しないこと、
 * 途中で切れたエントリや壊れたマルチバイト文字を渡さないことが要件。
 */
describe("session-learnings.sh", () => {
  it("learnings.md が無ければ何も注入しない", () => {
    const r = runSessionLearnings();

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("空の learnings.md でも何も注入しない", () => {
    const r = runSessionLearnings("");

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toBe("");
  });

  it("小さい learnings.md は全エントリを注入する", () => {
    const md = [
      "## 2026-07-20: hooks は node と jq を前提にしている",
      "PATH に無い環境では静かにスキップされる。",
      "",
      "## 2026-07-25: goal.md は .gitignore に入れる",
      "untracked のままだと stop-gate の変更なし判定を汚染する。",
      "",
    ].join("\n");

    const r = runSessionLearnings(md);

    expect(r.context).toContain("hooks は node と jq を前提にしている");
    expect(r.context).toContain("goal.md は .gitignore に入れる");
    // 全文が載っているので切り詰めの注記は付かない
    expect(r.context).not.toContain("末尾のみ");
  });

  describe("8000 バイトを超える場合", () => {
    // 日本語 (1文字3バイト) で 8000 バイトを十分に超えるファイルを作る
    const entries = Array.from({ length: 60 }, (_, i) =>
      [`## 2026-07-01: 見出し その${i + 1}`, "日本語の本文。".repeat(20), ""].join("\n"),
    );
    const big = entries.join("\n");
    const result = () => runSessionLearnings(big);

    it("末尾だけを注入し、切り詰めたことを明示する", () => {
      const r = result();

      expect(Buffer.byteLength(big)).toBeGreaterThan(8000);
      expect(r.context).toContain("末尾のみ");
      // ヘッダ分を足しても元ファイルよりは十分小さい
      expect(Buffer.byteLength(r.context ?? "")).toBeLessThan(Buffer.byteLength(big));
      // 最後のエントリは必ず含まれる (新しいものほど下にある)
      expect(r.context).toContain("見出し その60");
    });

    it("途中で切れたエントリを渡さない (見出しから始まる)", () => {
      const r = result();
      const ctx = r.context ?? "";
      // ヘッダ行と本文は最初の空行で区切られる
      const body = ctx.slice(ctx.indexOf("\n\n") + 2);

      expect(body.startsWith("## ")).toBe(true);
    });

    it("マルチバイト文字が壊れず、awk のエラーも出さない", () => {
      const r = result();

      // tail -c がマルチバイト文字の途中で切ると
      // awk が "multibyte conversion failure" を stderr に出して停止していた
      expect(r.stderr).toBe("");
      expect(r.context).toBeDefined();
      expect(r.context).not.toContain("�");
    });
  });
});
