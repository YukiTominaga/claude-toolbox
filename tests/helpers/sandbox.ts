import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/** テスト対象の hook 本体 */
export const CHANGE_GATE = resolve(HERE, "../../hooks/change-gate.sh");
export const VERIFY_GATE = resolve(HERE, "../../hooks/verify-gate.sh");
export const SUBAGENT_GATE = resolve(HERE, "../../hooks/subagent-gate.sh");
export const STOP_GATE = resolve(HERE, "../../hooks/stop-gate.sh");
export const SESSION_LEARNINGS = resolve(HERE, "../../hooks/session-learnings.sh");
export const ADR_LINT = resolve(HERE, "../../scripts/adr-lint.sh");

/** 使い捨ての git リポジトリにする (hook はプロジェクトルートの特定に git を使う) */
function gitInit(dir: string): void {
  const opts = { cwd: dir, encoding: "utf8" as const };
  spawnSync("git", ["init", "-q"], opts);
  spawnSync("git", ["config", "user.email", "t@example.com"], opts);
  spawnSync("git", ["config", "user.name", "t"], opts);
  spawnSync("git", ["commit", "-q", "--allow-empty", "-m", "init"], opts);
}

/** ディレクトリを作りながらファイルを書く */
function writeAll(root: string, files: Record<string, string>): void {
  for (const [rel, content] of Object.entries(files)) {
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
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

export interface ChangeGateCase {
  /** 先にコミットしておくファイル (変更前の状態) */
  committed?: Record<string, string>;
  /** コミット後に書き換えるファイル (追跡済みファイルの変更として現れる) */
  modified?: Record<string, string>;
  /** 未追跡ファイルとして置くファイル (新規追加として現れる) */
  added?: Record<string, string>;
  stopHookActive?: boolean;
  env?: Record<string, string>;
  /** git リポジトリにしない (管理外での素通しを確認する) */
  noGit?: boolean;
}

/** change-gate.sh を使い捨ての git リポジトリで実行する */
export function runChangeGate(c: ChangeGateCase): { exitCode: number; stderr: string } {
  const root = mkdtempSync(join(tmpdir(), "change-gate-"));
  try {
    if (!c.noGit) gitInit(root);
    if (c.committed) {
      writeAll(root, c.committed);
      if (!c.noGit) {
        const opts = { cwd: root, encoding: "utf8" as const };
        spawnSync("git", ["add", "-A"], opts);
        spawnSync("git", ["commit", "-q", "-m", "base"], opts);
      }
    }
    if (c.modified) writeAll(root, c.modified);
    if (c.added) writeAll(root, c.added);

    const proc = spawnSync("bash", [CHANGE_GATE], {
      cwd: root,
      env: { ...process.env, CLAUDE_PROJECT_DIR: root, ...(c.env ?? {}) },
      input: JSON.stringify({ stop_hook_active: c.stopHookActive ?? false }),
      encoding: "utf8",
    });

    return { exitCode: proc.status ?? -1, stderr: proc.stderr ?? "" };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/** transcript に並べる印。実際の tool_use レコードに展開される */
export type TranscriptEvent =
  | { edit: string; tool?: "Write" | "Edit" | "MultiEdit" | "NotebookEdit" }
  | { agent: string; tool?: "Agent" | "Task" };

export interface VerifyGateCase {
  /** 作業ツリーに置くファイル (未追跡として現れる) */
  added?: Record<string, string>;
  /** transcript に記録されたツール呼び出しの並び (時系列) */
  events?: TranscriptEvent[];
  /** transcript ファイル自体を作らない */
  noTranscript?: boolean;
  /** JSONL の先頭に壊れた行を混ぜる */
  corruptTranscript?: boolean;
  env?: Record<string, string>;
  noGit?: boolean;
}

/** verify-gate.sh を使い捨ての git リポジトリで実行する */
export function runVerifyGate(c: VerifyGateCase): { exitCode: number; stderr: string } {
  const root = mkdtempSync(join(tmpdir(), "verify-gate-"));
  try {
    if (!c.noGit) gitInit(root);
    if (c.added) writeAll(root, c.added);

    const transcript = join(root, "transcript.jsonl");
    if (!c.noTranscript) {
      // 編集ツールの file_path は絶対パスで記録される。
      // 相対パスで書くと、プロジェクトルートを剥がす処理を検証できない
      const lines = (c.events ?? []).map((e) =>
        "edit" in e
          ? JSON.stringify({
              type: "assistant",
              message: {
                content: [
                  {
                    type: "tool_use",
                    name: e.tool ?? "Edit",
                    input: { file_path: join(root, e.edit) },
                  },
                ],
              },
            })
          : JSON.stringify({
              type: "assistant",
              message: {
                content: [
                  {
                    type: "tool_use",
                    name: e.tool ?? "Agent",
                    input: { subagent_type: e.agent, prompt: "x" },
                  },
                ],
              },
            }),
      );
      if (c.corruptTranscript) lines.unshift('{"type":"assistant","message":{"con');
      writeFileSync(transcript, lines.length ? `${lines.join("\n")}\n` : "");
    }

    const proc = spawnSync("bash", [VERIFY_GATE], {
      cwd: root,
      env: { ...process.env, CLAUDE_PROJECT_DIR: root, ...(c.env ?? {}) },
      input: JSON.stringify({ transcript_path: transcript }),
      encoding: "utf8",
    });

    return { exitCode: proc.status ?? -1, stderr: proc.stderr ?? "" };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

export interface StopGateCase {
  /** package.json の scripts.test に入れる中身。省略すると package.json を作らない */
  testScript?: string;
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
