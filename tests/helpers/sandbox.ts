import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/** テスト対象の hook 本体 */
export const GOAL_GATE = resolve(HERE, "../../hooks/goal-gate.sh");
export const SUBAGENT_GATE = resolve(HERE, "../../hooks/subagent-gate.sh");
export const STOP_GATE = resolve(HERE, "../../hooks/stop-gate.sh");
export const SESSION_LEARNINGS = resolve(HERE, "../../hooks/session-learnings.sh");
export const ADR_LINT = resolve(HERE, "../../scripts/adr-lint.sh");
export const EVAL_RUN = resolve(HERE, "../../scripts/eval-run.sh");

/** claude / node などが載っていない最小 PATH (CLI 不在の状況を作るため) */
const MINIMAL_PATH = "/usr/bin:/bin";

export interface RunResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  /** 実行後の .claude/goal.md の中身 */
  goalMd: string;
}

export interface Sandbox {
  /** CLAUDE_PROJECT_DIR として渡すディレクトリ */
  projectDir: string;
  /** 差し替えた HOME (goal-gate はここの .claude/logs に追記する) */
  homeDir: string;
  goalPath: string;
  /** fake claude が標準出力に返す judge 応答を設定する */
  setJudgeResponse(judgeOutput: string, totalCostUsd?: number): void;
  /** fake claude が呼ばれた回数 */
  judgeCallCount(): number;
  /** fake claude に渡されたプロンプト (未呼び出しなら undefined) */
  judgePrompt(): string | undefined;
  /** DC の検証コマンドとして実行される fake npm の終了コード (既定 0) */
  setVerifyExitCode(code: number): void;
  /** fake npm に stdin を読み尽くさせる (heredoc 継承バグの再現用) */
  setVerifyConsumesStdin(on: boolean): void;
  /** fake npm が呼ばれた回数 */
  verifyCallCount(): number;
  /** .claude/goal.md を git の管理下に置く */
  trackGoalInGit(): void;
  /** $HOME/.claude/logs/goal-gate.jsonl の中身 (無ければ空文字) */
  readGateLog(): string;
  writeGoal(content: string): void;
  readGoal(): string;
  /**
   * withoutClaude: claude CLI が PATH に無い状況を再現する
   * fromSubdir: プロジェクト直下ではなくこのサブディレクトリから実行する
   *             (CLAUDE_PROJECT_DIR も渡さない。git トップレベルへのフォールバック検証用)
   */
  run(options?: {
    withoutClaude?: boolean;
    fromSubdir?: string;
    /** 追加の環境変数 (再入ガードの検証などに使う) */
    env?: Record<string, string>;
  }): RunResult;
  cleanup(): void;
}

/**
 * 使い捨てのサンドボックスで goal-gate.sh を実行するためのヘルパ。
 *
 * - `claude` は PATH 先頭に置いた fake に差し替える (実際の API を叩かせない)
 * - HOME もサンドボックス配下に差し替える
 *   (goal-gate は $HOME/.claude/logs/goal-gate.jsonl に追記するため)
 */
export function createSandbox(goalMd: string): Sandbox {
  const root = mkdtempSync(join(tmpdir(), "goal-gate-"));
  const projectDir = join(root, "project");
  const homeDir = join(root, "home");
  const binDir = join(root, "bin");
  const goalPath = join(projectDir, ".claude", "goal.md");
  const callsPath = join(root, "claude-calls.log");
  const responsePath = join(root, "claude-response.json");
  const promptPath = join(root, "claude-prompt.txt");
  const transcriptPath = join(root, "transcript.jsonl");
  const npmCallsPath = join(root, "npm-calls.log");
  const npmExitPath = join(root, "npm-exit.txt");
  const npmStdinPath = join(root, "npm-consume-stdin");

  mkdirSync(join(projectDir, ".claude"), { recursive: true });
  mkdirSync(homeDir, { recursive: true });
  mkdirSync(binDir, { recursive: true });
  writeFileSync(goalPath, goalMd);
  writeFileSync(transcriptPath, "");

  // CLAUDE_PROJECT_DIR 未設定時に git のトップレベルへフォールバックする挙動を試せるようにする
  gitInit(projectDir);

  // fake claude: 呼び出しを記録し、標準入力(プロンプト)を捨て、用意した応答を返すだけ
  const fake = [
    "#!/bin/sh",
    `printf 'call\\n' >> '${callsPath}'`,
    `cat > '${promptPath}'`,
    `cat '${responsePath}'`,
    "",
  ].join("\n");
  const fakeClaude = join(binDir, "claude");
  writeFileSync(fakeClaude, fake);
  chmodSync(fakeClaude, 0o755);

  // fake npm: goal-gate が DC の検証コマンドを実際に実行するようになったため、
  // サンドボックスに本物の npm を走らせないよう差し替える
  const fakeNpm = join(binDir, "npm");
  writeFileSync(
    fakeNpm,
    [
      "#!/bin/sh",
      `printf 'call\\n' >> '${npmCallsPath}'`,
      // stdin を読み尽くす挙動を再現できるようにする
      `[ -f '${npmStdinPath}' ] && cat > /dev/null`,
      `exit "$(cat '${npmExitPath}')"`,
      "",
    ].join("\n"),
  );
  chmodSync(fakeNpm, 0o755);
  writeFileSync(npmExitPath, "0");

  return {
    projectDir,
    homeDir,
    goalPath,

    setJudgeResponse(judgeOutput: string, totalCostUsd?: number) {
      // claude -p --output-format json のエンベロープを模す
      const envelope: Record<string, unknown> = { result: judgeOutput };
      if (totalCostUsd !== undefined) envelope.total_cost_usd = totalCostUsd;
      writeFileSync(responsePath, JSON.stringify(envelope));
    },

    judgeCallCount() {
      if (!existsSync(callsPath)) return 0;
      return readFileSync(callsPath, "utf8").split("\n").filter(Boolean).length;
    },

    judgePrompt() {
      if (!existsSync(promptPath)) return undefined;
      return readFileSync(promptPath, "utf8");
    },

    setVerifyExitCode(code: number) {
      writeFileSync(npmExitPath, String(code));
    },

    setVerifyConsumesStdin(on: boolean) {
      if (on) writeFileSync(npmStdinPath, "1");
      else rmSync(npmStdinPath, { force: true });
    },

    verifyCallCount() {
      if (!existsSync(npmCallsPath)) return 0;
      return readFileSync(npmCallsPath, "utf8").split("\n").filter(Boolean).length;
    },

    trackGoalInGit() {
      const opts = { cwd: projectDir, encoding: "utf8" as const };
      spawnSync("git", ["add", "-f", ".claude/goal.md"], opts);
      spawnSync("git", ["commit", "-q", "-m", "add goal"], opts);
    },

    readGateLog() {
      const p = join(homeDir, ".claude", "logs", "goal-gate.jsonl");
      return existsSync(p) ? readFileSync(p, "utf8") : "";
    },

    writeGoal(content: string) {
      writeFileSync(goalPath, content);
    },

    readGoal() {
      return readFileSync(goalPath, "utf8");
    },

    run(
      options: {
        withoutClaude?: boolean;
        fromSubdir?: string;
        env?: Record<string, string>;
      } = {},
    ): RunResult {
      const env = { ...process.env };
      delete env.CRYSTAL_GOAL_JUDGE;
      delete env.CRYSTAL_GOAL_VERIFY;
      env.HOME = homeDir;
      env.PATH = options.withoutClaude
        ? MINIMAL_PATH
        : `${binDir}:${process.env.PATH ?? ""}`;

      let cwd = projectDir;
      if (options.fromSubdir) {
        cwd = join(projectDir, options.fromSubdir);
        mkdirSync(cwd, { recursive: true });
        delete env.CLAUDE_PROJECT_DIR;
      } else {
        env.CLAUDE_PROJECT_DIR = projectDir;
      }
      Object.assign(env, options.env ?? {});

      const proc = spawnSync("bash", [GOAL_GATE], {
        cwd,
        env,
        input: JSON.stringify({
          session_id: "t",
          transcript_path: transcriptPath,
        }),
        encoding: "utf8",
      });

      return {
        exitCode: proc.status ?? -1,
        stdout: proc.stdout ?? "",
        stderr: proc.stderr ?? "",
        goalMd: readFileSync(goalPath, "utf8"),
      };
    },

    cleanup() {
      rmSync(root, { recursive: true, force: true });
    },
  };
}

/** 使い捨ての git リポジトリにする (hook はプロジェクトルートの特定に git を使う) */
function gitInit(dir: string): void {
  const opts = { cwd: dir, encoding: "utf8" as const };
  spawnSync("git", ["init", "-q"], opts);
  spawnSync("git", ["config", "user.email", "t@example.com"], opts);
  spawnSync("git", ["config", "user.name", "t"], opts);
  spawnSync("git", ["commit", "-q", "--allow-empty", "-m", "init"], opts);
}

/**
 * session-learnings.sh を使い捨てディレクトリで実行する。
 * learnings が undefined なら .claude/learnings.md を作らない。
 */
export function runSessionLearnings(learnings?: string): {
  exitCode: number;
  stdout: string;
  stderr: string;
  /** additionalContext。出力が無ければ undefined */
  context?: string;
} {
  const root = mkdtempSync(join(tmpdir(), "session-learnings-"));
  try {
    gitInit(root);
    mkdirSync(join(root, ".claude"), { recursive: true });
    if (learnings !== undefined) {
      writeFileSync(join(root, ".claude", "learnings.md"), learnings);
    }

    const proc = spawnSync("bash", [SESSION_LEARNINGS], {
      cwd: root,
      env: { ...process.env, CLAUDE_PROJECT_DIR: root },
      input: JSON.stringify({ hook_event_name: "SessionStart", source: "startup" }),
      encoding: "utf8",
    });

    const stdout = proc.stdout ?? "";
    let context: string | undefined;
    if (stdout.trim()) {
      context = JSON.parse(stdout).hookSpecificOutput.additionalContext;
    }
    return { exitCode: proc.status ?? -1, stdout, stderr: proc.stderr ?? "", context };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/**
 * adr-lint.sh を使い捨てディレクトリで実行する。
 * files のキーは docs/adr/ 配下のファイル名、値はその中身。
 * dir を渡すと docs/adr 以外を検査対象にする (ディレクトリ不在の検証用)。
 */
export function runAdrLint(
  files: Record<string, string>,
  dir?: string,
): { exitCode: number; stdout: string } {
  const root = mkdtempSync(join(tmpdir(), "adr-lint-"));
  try {
    const adrDir = join(root, "docs", "adr");
    mkdirSync(adrDir, { recursive: true });
    for (const [name, content] of Object.entries(files)) {
      writeFileSync(join(adrDir, name), content);
    }

    const proc = spawnSync("bash", dir ? [ADR_LINT, dir] : [ADR_LINT], {
      cwd: root,
      encoding: "utf8",
    });
    return { exitCode: proc.status ?? -1, stdout: proc.stdout ?? "" };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/** eval-run.sh を、ケース 1 件だけを置いた使い捨てリポジトリで実行する */
export function runEvalRun(caseMd: string, id = "c1"): { exitCode: number; stdout: string } {
  const root = mkdtempSync(join(tmpdir(), "eval-run-"));
  try {
    gitInit(root);
    mkdirSync(join(root, "evals", "cases"), { recursive: true });
    writeFileSync(join(root, "evals", "cases", `${id}.md`), caseMd);

    const proc = spawnSync("bash", [EVAL_RUN], {
      cwd: root,
      env: { ...process.env, CLAUDE_PROJECT_DIR: root },
      encoding: "utf8",
    });
    return { exitCode: proc.status ?? -1, stdout: proc.stdout ?? "" };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

export interface StopGateCase {
  /** package.json の scripts.test に入れる中身。省略すると package.json を作らない */
  testScript?: string;
  /** .claude/goal.md の status。null なら goal.md を作らない */
  goalStatus?: "active" | "done" | null;
  /** 完了条件に併記する検証コマンド (省略時は検証コマンドなしの DC を書く) */
  goalVerifyCmd?: string;
  stopHookActive?: boolean;
}

/** stop-gate.sh を使い捨ての git リポジトリで実行する */
export function runStopGate(c: StopGateCase): { exitCode: number; stderr: string } {
  const root = mkdtempSync(join(tmpdir(), "stop-gate-"));
  try {
    gitInit(root);
    if (c.testScript !== undefined) {
      writeFileSync(
        join(root, "package.json"),
        JSON.stringify({ name: "t", private: true, scripts: { test: c.testScript } }),
      );
    }
    if (c.goalStatus) {
      mkdirSync(join(root, ".claude"), { recursive: true });
      writeFileSync(
        join(root, ".claude", "goal.md"),
        [
          "---",
          `status: ${c.goalStatus}`,
          "round: 1",
          "max_rounds: 5",
          "---",
          "# g",
          "",
          "## 完了条件",
          "",
          c.goalVerifyCmd
            ? `- [ ] DC-1: テストが通る — 検証: \`${c.goalVerifyCmd}\` が exit 0`
            : "- [ ] DC-1: 見た目が整っている",
          "",
        ].join("\n"),
      );
    }
    // 変更が無いと stop-gate はゲート不要として素通しするため、未追跡ファイルを置く
    writeFileSync(join(root, "dirty.txt"), "x\n");

    const proc = spawnSync("bash", [STOP_GATE], {
      cwd: root,
      env: { ...process.env, CLAUDE_PROJECT_DIR: root },
      input: JSON.stringify({ stop_hook_active: c.stopHookActive ?? false }),
      encoding: "utf8",
    });

    return { exitCode: proc.status ?? -1, stderr: proc.stderr ?? "" };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

export interface SubagentCase {
  /** サブエージェントの最終出力 */
  lastMessage: string;
  /** そのサブエージェントが実行した Bash コマンド */
  commands?: string[];
  /**
   * そのサブエージェントが Write したファイル。
   * 変更痕跡が 1 件も無いエージェントはゲートの対象外になるため、
   * 差し戻しを期待するケースでは必ず指定する。
   */
  edits?: string[];
  /** edits を記録するツール名 (既定 Write) */
  editTool?: "Write" | "Edit" | "MultiEdit" | "NotebookEdit";
  stopHookActive?: boolean;
  /** transcript ファイル自体を壊す (JSONL の途中行が不正なケース) */
  corruptTranscript?: boolean;
}

/** subagent-gate.sh を使い捨てディレクトリで実行する */
export function runSubagentGate(c: SubagentCase): { exitCode: number; stderr: string } {
  const root = mkdtempSync(join(tmpdir(), "subagent-gate-"));
  try {
    const transcript = join(root, "agent.jsonl");
    const lines = [
      ...(c.edits ?? []).map((file_path) =>
        JSON.stringify({
          type: "assistant",
          message: {
            content: [
              { type: "tool_use", name: c.editTool ?? "Write", input: { file_path, content: "x" } },
            ],
          },
        }),
      ),
      ...(c.commands ?? []).map((command) =>
        JSON.stringify({
          type: "assistant",
          message: { content: [{ type: "tool_use", name: "Bash", input: { command } }] },
        }),
      ),
    ];
    if (c.corruptTranscript) lines.unshift('{"type":"assistant","message":{"con');
    writeFileSync(transcript, lines.length ? `${lines.join("\n")}\n` : "");

    const env = { ...process.env, HOME: join(root, "home") };
    mkdirSync(env.HOME, { recursive: true });

    const proc = spawnSync("bash", [SUBAGENT_GATE], {
      env,
      input: JSON.stringify({
        agent_id: "a1",
        agent_type: "workflow-subagent",
        stop_hook_active: c.stopHookActive ?? false,
        last_assistant_message: c.lastMessage,
        agent_transcript_path: transcript,
      }),
      encoding: "utf8",
    });

    return { exitCode: proc.status ?? -1, stderr: proc.stderr ?? "" };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/** goal.md の frontmatter から値を取り出す (テスト側の検証用) */
export function frontmatterField(goalMd: string, key: string): string | undefined {
  const lines = goalMd.split("\n");
  if (lines[0] !== "---") return undefined;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === "---") return undefined;
    const m = lines[i].match(new RegExp(`^${key}:\\s*(.*)$`));
    if (m) return m[1].trim();
  }
  return undefined;
}

/** 「## 判定履歴」セクションの箇条書き行 */
export function historyEntries(goalMd: string): string[] {
  const lines = goalMd.split("\n");
  const start = lines.findIndex((l) => l.startsWith("## 判定履歴"));
  if (start === -1) return [];
  const entries: string[] = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i].startsWith("## ")) break;
    if (lines[i].startsWith("- ")) entries.push(lines[i]);
  }
  return entries;
}
