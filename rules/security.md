# Security

## Secrets

- Never hardcode secrets (API keys, tokens, passwords, connection strings) in
  source code, config files, or test fixtures. Use environment variables or a
  secret manager.
- Never read, print, or copy the contents of credential files
  (`~/.ssh/`, `~/.aws/`, `.env`, keychains) into the conversation, logs, or code.
- Before committing, check the diff for accidentally included secrets.

## Input Validation

Validate and sanitize external input (user input, API responses, file
contents) at the boundary before using it. Never build shell commands or SQL
by string-concatenating untrusted input.

## Dependencies

Prefer well-known, maintained packages. Do not pipe remote scripts into a
shell (`curl ... | sh`). Review what an install script does before running it.
