import { afterEach, describe, expect, it } from "vitest";
import {
  createSandbox,
  frontmatterField,
  historyEntries,
  type Sandbox,
} from "./helpers/sandbox";

/**
 * goal-gate.sh は fail-open 設計 (異常時は exit 0 で沈黙する) であり、
 * かつ awk + mv でユーザーの .claude/goal.md を直接書き換える。
 * この 2 点は手動 E2E では壊れても気づけないため、そこだけをテストする。
 */

function goalMd(fields: Record<string, string | number> = {}): string {
  const fm = {
    status: "active",
    round: 0,
    max_rounds: 5,
    cost_usd: 0,
    created: "2026-07-26",
    ...fields,
  };
  return [
    "---",
    ...Object.entries(fm).map(([k, v]) => `${k}: ${v}`),
    "---",
    "# ゴール: テスト用ゴール",
    "",
    "## 完了条件",
    "",
    "- [ ] DC-1: テストが通る — 検証: `npm test` が exit 0",
    "",
    "## 制約",
    "",
    "- C-1: 既存の公開 API を壊さないこと",
    "",
    "## 判定履歴",
    "",
  ].join("\n");
}

let sandboxes: Sandbox[] = [];

function sandbox(md: string): Sandbox {
  const s = createSandbox(md);
  sandboxes.push(s);
  return s;
}

afterEach(() => {
  for (const s of sandboxes) s.cleanup();
  sandboxes = [];
});

describe("goal-gate.sh", () => {
  it("round が max_rounds を超えたら judge を呼ばずに stalled で停止する", () => {
    const s = sandbox(goalMd({ round: 5, max_rounds: 5 }));
    s.setJudgeResponse(JSON.stringify({ met: false, unmet: ["DC-1"] }), 0.01);

    const r = s.run();

    expect(r.exitCode).toBe(0);
    expect(frontmatterField(r.goalMd, "status")).toBe("stalled");
    // 無限ループ対策: 上限に達したら judge (課金) を一切呼ばないこと
    expect(s.judgeCallCount()).toBe(0);
  });

  it("met:true なら done で exit 0、met:false なら exit 2 で判定履歴に 1 件追記される", () => {
    const met = sandbox(goalMd());
    met.setJudgeResponse(
      JSON.stringify({ met: true, unmet: [], violations: [], reason: "全条件を確認" }),
      0.01,
    );
    const rMet = met.run();

    expect(rMet.exitCode).toBe(0);
    expect(frontmatterField(rMet.goalMd, "status")).toBe("done");
    expect(historyEntries(rMet.goalMd)).toEqual(["- r1: 達成 — 全条件を確認"]);

    const unmet = sandbox(goalMd());
    unmet.setJudgeResponse(
      JSON.stringify({
        met: false,
        unmet: ["DC-1"],
        violations: [],
        reason: "検証コマンドの出力が無い",
      }),
      0.01,
    );
    const rUnmet = unmet.run();

    expect(rUnmet.exitCode).toBe(2);
    expect(frontmatterField(rUnmet.goalMd, "status")).toBe("active");
    expect(frontmatterField(rUnmet.goalMd, "round")).toBe("1");
    const entries = historyEntries(rUnmet.goalMd);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatch(/^- r1: 未達 \[DC-1\]/);
    expect(rUnmet.stderr).toContain("未達条件: DC-1");
  });

  it("met:true でも violations が非空なら未達扱いになる (ゴールドリフト対策)", () => {
    const s = sandbox(goalMd());
    s.setJudgeResponse(
      JSON.stringify({
        met: true,
        unmet: [],
        violations: ["C-1"],
        reason: "公開 API のシグネチャを変更している",
      }),
      0.01,
    );

    const r = s.run();

    expect(r.exitCode).toBe(2);
    expect(frontmatterField(r.goalMd, "status")).toBe("active");
    expect(historyEntries(r.goalMd)[0]).toContain("制約違反 [C-1]");
    expect(r.stderr).toContain("制約違反: C-1");
  });

  it("cost_usd が judge 呼び出しごとに累積する", () => {
    const s = sandbox(goalMd());
    s.setJudgeResponse(
      JSON.stringify({ met: false, unmet: ["DC-1"], violations: [], reason: "継続中" }),
      0.01,
    );

    const first = s.run();
    expect(Number(frontmatterField(first.goalMd, "cost_usd"))).toBeCloseTo(0.01, 4);

    const second = s.run();
    expect(Number(frontmatterField(second.goalMd, "cost_usd"))).toBeCloseTo(0.02, 4);
    expect(s.judgeCallCount()).toBe(2);
  });

  it("judge 出力が JSON として解釈できなければ fail-open し goal.md も壊さない", () => {
    const s = sandbox(goalMd());
    s.setJudgeResponse("判定できませんでした。もう少し情報が必要です。", 0.01);

    const r = s.run();

    expect(r.exitCode).toBe(0);
    // 判定不能を「達成」にも「未達で差し戻し」にもしない
    expect(frontmatterField(r.goalMd, "status")).toBe("active");
    expect(frontmatterField(r.goalMd, "round")).toBe("1");
    expect(frontmatterField(r.goalMd, "max_rounds")).toBe("5");
    // frontmatter が壊れていない (--- で開いて --- で閉じている)
    expect(r.goalMd.split("\n").filter((l) => l === "---")).toHaveLength(2);
    expect(historyEntries(r.goalMd)).toEqual([]);
  });

  // --- 以下はレビューで見つかったバグの回帰テスト ---

  it("reason に改行やバックスラッシュが含まれても判定履歴が失われない", () => {
    // awk の -v で値を渡していたとき、改行があると awk 自体が落ちて追記が丸ごと消えていた。
    // バックスラッシュは -v のエスケープ展開で \t → タブ等に化けていた。
    const s = sandbox(goalMd());
    s.setJudgeResponse(
      JSON.stringify({
        met: false,
        unmet: ["DC-1"],
        violations: [],
        reason: "未達です。\n再現手順:\n  npm test を実行\nパス C:\\new\\test も確認",
      }),
      0.01,
    );

    const r = s.run();

    expect(r.exitCode).toBe(2);
    const entries = historyEntries(r.goalMd);
    expect(entries).toHaveLength(1);
    expect(entries[0]).toContain("C:\\new\\test");
    // 1 行に収まっていること (改行が残ると Markdown の箇条書きが壊れる)
    expect(entries[0]).not.toContain("\n");
  });

  it("frontmatter が壊れた goal.md には触らず fail-open する", () => {
    // 閉じ --- が無く round 行も無い場合、update_field が黙って何も書けず
    // round が永久に永続化されないため、max_rounds に到達せず無限に差し戻し続けていた。
    const broken = ["---", "status: active", "max_rounds: 5", "", "## 完了条件", "- DC-1: x", ""].join(
      "\n",
    );
    const s = sandbox(broken);
    s.setJudgeResponse(JSON.stringify({ met: false, unmet: ["DC-1"] }), 0.01);

    for (let i = 0; i < 3; i++) {
      const r = s.run();
      expect(r.exitCode).toBe(0);
      expect(r.goalMd).toBe(broken);
    }
    expect(s.judgeCallCount()).toBe(0);
  });

  it("CLAUDE_PROJECT_DIR が無くてもリポジトリルートの goal.md を見つける", () => {
    // `cd .` は必ず成功するため `cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0` はガードにならず、
    // 未設定時はカレント(サブパッケージ等)を見て goal.md を静かに見失っていた
    const s = sandbox(goalMd());
    s.setJudgeResponse(
      JSON.stringify({ met: false, unmet: ["DC-1"], violations: [], reason: "継続" }),
      0.01,
    );

    const r = s.run({ fromSubdir: "packages/api" });

    expect(r.exitCode).toBe(2);
    expect(frontmatterField(r.goalMd, "round")).toBe("1");
  });

  it("claude CLI が無いときはラウンドを消費しない", () => {
    // 判定できない環境でラウンドだけ減り、判定ゼロのまま stalled に落ちるのを防ぐ
    const s = sandbox(goalMd());
    s.setJudgeResponse(JSON.stringify({ met: true }), 0.01);

    const r = s.run({ withoutClaude: true });

    expect(r.exitCode).toBe(0);
    expect(frontmatterField(r.goalMd, "round")).toBe("0");
    expect(frontmatterField(r.goalMd, "status")).toBe("active");
  });
});
