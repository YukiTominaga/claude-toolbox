#!/usr/bin/env node
// PostToolUse(Bash, async) logger: appends executed commands to
// ~/.claude/logs/bash-YYYY-MM.jsonl for later retrospectives (/learn).
// Always exits 0.

const fs = require('fs');
const path = require('path');
const os = require('os');

let raw = '';
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', () => {
  try {
    const input = JSON.parse(raw || '{}');
    const command = (input.tool_input && input.tool_input.command) || '';
    if (!command) process.exit(0);
    const now = new Date();
    const dir = path.join(os.homedir(), '.claude', 'logs');
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(
      dir,
      `bash-${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}.jsonl`
    );
    const entry = {
      ts: now.toISOString(),
      cwd: input.cwd || '',
      session_id: input.session_id || '',
      command,
      description: (input.tool_input && input.tool_input.description) || '',
    };
    fs.appendFileSync(file, JSON.stringify(entry) + '\n');
  } catch (e) {
    process.stderr.write(`[log-bash] ${e.message}\n`);
  }
  process.exit(0);
});
