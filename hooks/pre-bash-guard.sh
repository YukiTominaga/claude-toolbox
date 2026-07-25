#!/usr/bin/env node
// PreToolUse(Bash) guard: blocks destructive commands.
// Reads hook JSON on stdin. On match, prints a permissionDecision=deny JSON.
// Always exits 0 (never blocks tool execution by accident on parse errors).

const RULES = [
  {
    // rm -rf (any flag order) targeting root, home or $HOME
    re: /\brm\s+(-[a-z]*r[a-z]*f[a-z]*|-[a-z]*f[a-z]*r[a-z]*|-r\s+-f|-f\s+-r)\s+(?:["']?)(\/\s*$|\/\*|\/\s|~\/?(\s|$|["'])|\$HOME\b)/i,
    reason: 'rm -rf targeting root or home directory is blocked',
  },
  {
    re: /\brm\b[^|;&]*--no-preserve-root/i,
    reason: 'rm with --no-preserve-root is blocked',
  },
  {
    // force push to main/master (allow --force-with-lease)
    re: /\bgit\s+push\b(?=[^|;&]*(?:--force(?!-with-lease)|\s-f\b))[^|;&]*\b(main|master)\b/i,
    reason: 'Force push to main/master is blocked (use a feature branch, or --force-with-lease elsewhere)',
  },
  {
    re: /\bchmod\s+(-[a-z]*R[a-z]*\s+)?777\s+\//i,
    reason: 'chmod 777 on a root path is blocked',
  },
  {
    re: /\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b/i,
    reason: 'Piping a remote script into a shell is blocked; download and review it first',
  },
  {
    re: /\bdd\b[^|;&]*\bof=\/dev\/(disk|sd|hd|nvme)/i,
    reason: 'dd writing to a raw disk device is blocked',
  },
  {
    re: /\bmkfs(\.\w+)?\b/i,
    reason: 'Filesystem formatting (mkfs) is blocked',
  },
];

// Gates from LOOP.md that require a human's approval. A human is present in an
// interactive session and can approve, so these are only denied when the loop runs
// unattended (CRYSTAL_UNATTENDED=1) — there is nobody to ask, and "ask" would mean
// "hang until the budget runs out".
const UNATTENDED_RULES = [
  {
    re: /\bgh\s+pr\s+(create|merge|ready)\b/i,
    reason: 'Creating or merging a pull request is a gate; report it instead of doing it',
  },
  {
    re: /\bgit\s+merge\b/i,
    reason: 'Merging is a gate; report it instead of doing it',
  },
  {
    re: /\b(npm|pnpm|yarn|bun)\s+(i|install|add)\b(?!.*--dry-run)/i,
    reason: 'Adding or updating dependencies is a gate; report it instead of doing it',
  },
  {
    re: /\b(pip3?|uv)\s+(install|add)\b/i,
    reason: 'Adding or updating dependencies is a gate; report it instead of doing it',
  },
  {
    re: /\bgit\s+push\b[^|;&]*(--force(?!-with-lease)|\s-f\b)/i,
    reason: 'Force pushing is out of scope for the loop',
  },
];

let raw = '';
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', () => {
  try {
    const input = JSON.parse(raw || '{}');
    const command = String((input.tool_input && input.tool_input.command) || '');
    if (!command) process.exit(0);
    const rules =
      process.env.CRYSTAL_UNATTENDED === '1' ? RULES.concat(UNATTENDED_RULES) : RULES;
    for (const rule of rules) {
      if (rule.re.test(command)) {
        process.stdout.write(
          JSON.stringify({
            hookSpecificOutput: {
              hookEventName: 'PreToolUse',
              permissionDecision: 'deny',
              permissionDecisionReason: `[pre-bash-guard] ${rule.reason}`,
            },
          })
        );
        process.exit(0);
      }
    }
  } catch (e) {
    // Parse errors must never block tool execution
  }
  process.exit(0);
});
