#!/usr/bin/env node
// PostToolUse(Write|Edit|MultiEdit): formats the edited file with the
// project's own Prettier, if one is installed. Does nothing otherwise.
// Always exits 0 (formatting must never block the session).

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const EXTS = new Set([
  '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs',
  '.json', '.css', '.scss', '.html', '.md', '.yaml', '.yml',
]);

function findPrettier(startDir) {
  const home = os.homedir();
  let dir = startDir;
  while (true) {
    const bin = path.join(dir, 'node_modules', '.bin', 'prettier');
    if (fs.existsSync(bin)) return bin;
    const parent = path.dirname(dir);
    if (parent === dir || dir === home) return null;
    dir = parent;
  }
}

let raw = '';
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', () => {
  try {
    const input = JSON.parse(raw || '{}');
    const filePath = (input.tool_input && input.tool_input.file_path) || '';
    if (!filePath || !EXTS.has(path.extname(filePath))) process.exit(0);
    if (!fs.existsSync(filePath)) process.exit(0);
    const prettier = findPrettier(path.dirname(filePath));
    if (!prettier) process.exit(0);
    spawnSync(prettier, ['--write', '--ignore-unknown', filePath], {
      timeout: 10000,
      stdio: 'ignore',
    });
  } catch (e) {
    process.stderr.write(`[format-on-save] ${e.message}\n`);
  }
  process.exit(0);
});
