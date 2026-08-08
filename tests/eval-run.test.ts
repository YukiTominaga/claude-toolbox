import { describe, expect, it } from "vitest";
import { runEvalRun } from "./helpers/sandbox";

/**
 * frontmatter のパースが run: を壊すと、ケースの中身と無関係に FAIL が出る。
 * eval は「二度と壊したくない挙動」を貯める場所なので、
 * ランナー側の誤判定は再発防止の資産そのものを信用できなくする。
 */

function commandCase(run: string, expectExit = 0): string {
  return [
    "---",
    "id: c1",
    "type: command",
    "description: テスト用",
    `run: ${run}`,
    `expect_exit: ${expectExit}`,
    "---",
    "## メモ",
    "",
    "テスト用ケース。",
    "",
  ].join("\n");
}

describe("eval-run.sh", () => {
  it('run: が " で終わっても構文エラーにならない', () => {
    // 囲みクォートの除去が片側だけでも効いていると、末尾の " が剥がされて
    // `bash -c 'bash -c "exit 0'` となり、ケースと無関係に exit 2 で落ちる
    const r = runEvalRun(commandCase('bash -c "exit 0"'));

    expect(r.stdout).toContain("PASS");
    expect(r.exitCode).toBe(0);
  });

  it("両端が囲みクォートなら外して実行する", () => {
    // 外し忘れると `"echo ok"` 全体がコマンド名として扱われ 127 になる
    const r = runEvalRun(commandCase('"echo ok"'));

    expect(r.stdout).toContain("PASS");
    expect(r.exitCode).toBe(0);
  });

  it("expect_exit と食い違えば FAIL する", () => {
    const r = runEvalRun(commandCase('bash -c "exit 3"'));

    expect(r.stdout).toContain("FAIL");
    expect(r.exitCode).toBe(1);
  });

  it("CLAUDE_PLUGIN_ROOT をケースから参照できる", () => {
    // ケースはプロジェクトの git 管理下に置かれるため、環境ごとに違う
    // プラグインのインストール先を埋め込めない
    const r = runEvalRun(commandCase('bash "$CLAUDE_PLUGIN_ROOT/scripts/adr-lint.sh"'));

    expect(r.stdout).toContain("PASS");
    expect(r.exitCode).toBe(0);
  });
});
