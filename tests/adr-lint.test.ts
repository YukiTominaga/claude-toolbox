import { describe, expect, it } from "vitest";
import { runAdrLint } from "./helpers/sandbox";

/**
 * /crystal:adr の指示のうち機械判定できる部分を adr-lint.sh に移してある。
 * 散文の禁止事項は守られたかを確認する手段が無いため、ここで押さえるのは
 * 「lint が本当に違反を検出するか」と「妥当な ADR を誤検出しないか」の 2 点。
 * 後者が壊れると全 ADR が赤くなり、lint ごと無視されるようになる。
 */

/** 妥当な ADR。overrides で 1 箇所だけ壊してケースを作る */
function adr(overrides: { num?: string; status?: string; date?: string } = {}): string {
  const { num = "0001", status = "accepted", date = "2026-08-08" } = overrides;
  return [
    `# ADR-${num}: PostgreSQL を採用する`,
    "",
    `- ステータス: ${status}`,
    `- 日付: ${date}`,
    "",
    "## コンテキスト",
    "",
    "集計要件が JOIN を多用する。",
    "",
    "## 決定",
    "",
    "PostgreSQL 16 を採用する。",
    "",
    "## 検討した選択肢",
    "",
    "### 案 A: PostgreSQL(採用)",
    "",
    "- JOIN 性能と運用実績",
    "",
    "### 案 B: DynamoDB(却下)",
    "",
    "- 却下理由: 集計クエリが表現できない",
    "",
    "## 影響",
    "",
    "### 得られるもの",
    "",
    "- 集計をアプリ側に持たなくてよい",
    "",
    "### 受け入れるトレードオフ",
    "",
    "- 水平スケールの上限が早い",
    "",
  ].join("\n");
}

describe("adr-lint.sh", () => {
  it("妥当な ADR は指摘なしで通る", () => {
    const r = runAdrLint({ "0001-use-postgres.md": adr() });

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("指摘なし");
  });

  it("ADR ディレクトリが無ければ検査対象なしで通る", () => {
    const r = runAdrLint({}, "docs/adr-missing");

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("検査対象なし");
  });

  it("ADR が 1 件も無ければ検査対象なしで通る", () => {
    const r = runAdrLint({});

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("検査対象なし");
  });

  it("ファイル名が NNNN-slug.md でなければ指摘する", () => {
    const r = runAdrLint({ "use-postgres.md": adr() });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("ファイル名が NNNN-slug.md 形式でない");
  });

  it("番号の重複を検出する (並行ブランチでの採番衝突)", () => {
    // 別ブランチで同じ番号の ADR が生まれるのは散文の手順では防げない
    const r = runAdrLint({
      "0001-use-postgres.md": adr(),
      "0001-use-mysql.md": adr(),
    });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("ADR 番号 0001 が重複している");
  });

  it("見出しの番号がファイル名と一致しなければ指摘する", () => {
    const r = runAdrLint({ "0002-use-postgres.md": adr({ num: "0001" }) });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("見出しの番号 (0001) がファイル名 (0002) と一致しない");
  });

  it("日付が YYYY-MM-DD 形式でなければ指摘する", () => {
    const r = runAdrLint({ "0001-use-postgres.md": adr({ date: "2026/08/08" }) });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("日付が YYYY-MM-DD 形式でない");
  });

  it("ステータスの値が既定外なら指摘する", () => {
    const r = runAdrLint({ "0001-use-postgres.md": adr({ status: "wip" }) });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("ステータスの値が不正");
  });

  it("必須セクションの欠落を指摘する", () => {
    const broken = adr().replace("## 検討した選択肢\n", "## 選択肢\n");
    const r = runAdrLint({ "0001-use-postgres.md": broken });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("必須セクション '## 検討した選択肢' が無い");
  });

  it("却下案が 1 つも無ければ指摘する", () => {
    // 却下案の無い ADR は「なぜ他を採らなかったか」を残せておらず、主価値を欠く
    const broken = adr().replace("### 案 B: DynamoDB(却下)", "### 案 B: DynamoDB");
    const r = runAdrLint({ "0001-use-postgres.md": broken });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("却下した案が無い");
  });

  it("テンプレートのプレースホルダ残留を指摘する", () => {
    const broken = adr().replace("- 日付: 2026-08-08", "- 日付: YYYY-MM-DD");
    const r = runAdrLint({ "0001-use-postgres.md": broken });

    expect(r.exitCode).toBe(1);
    expect(r.stdout).toContain("プレースホルダ");
  });

  describe("supersede の整合", () => {
    it("参照先が存在しなければ指摘する", () => {
      const r = runAdrLint({
        "0001-use-postgres.md": adr({ status: "superseded by ADR-0002" }),
      });

      expect(r.exitCode).toBe(1);
      expect(r.stdout).toContain("superseded by ADR-0002 の参照先が存在しない");
    });

    it("逆リンクが無ければ指摘する (片側だけ更新した状態)", () => {
      const r = runAdrLint({
        "0001-use-postgres.md": adr({ status: "superseded by ADR-0002" }),
        "0002-move-to-spanner.md": adr({ num: "0002", date: "2026-08-09" }),
      });

      expect(r.exitCode).toBe(1);
      expect(r.stdout).toContain("ADR-0002 側に ADR-0001 への逆リンクが無い");
    });

    it("双方向リンクが揃っていれば通る", () => {
      const newer = adr({ num: "0002", date: "2026-08-09" }).replace(
        "- 日付: 2026-08-09",
        "- 日付: 2026-08-09\n- 関連: ADR-0001 を置き換える",
      );
      const r = runAdrLint({
        "0001-use-postgres.md": adr({ status: "superseded by ADR-0002" }),
        "0002-move-to-spanner.md": newer,
      });

      expect(r.exitCode).toBe(0);
      expect(r.stdout).toContain("指摘なし");
    });
  });
});
