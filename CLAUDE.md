# Claude Code

@AGENTS.md

## Claude Code specifics

- Subagents dispatched with the Agent tool get `isolation: "worktree"`, so
  each one works in its own worktree rather than in a shared checkout.
- Shared subagents live in `.claude/agents/`. Personal ones go in
  `.claude/agents/local/`, which is gitignored. Every agent `name` must be
  unique across both and across `~/.claude/agents/`.
- Shared settings live in `.claude/settings.json`. Personal overrides go in
  `.claude/settings.local.json`, which is gitignored.
- Personal notes go in `CLAUDE.local.md`, which is gitignored.
