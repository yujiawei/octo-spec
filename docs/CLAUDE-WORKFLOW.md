# Claude Code workflow

octo-spec is Claude Code first. The 4-phase loop maps to four slash commands
backed by thin scripts. No central server, no extra service — everything reads
and writes files in the repo.

## Zero install for team members

The slash commands **and** the auto-trigger skill are **committed to the repo**
under `.claude/`. A team member does **not** install anything: `git clone` /
`git pull` brings them with the repo.

- **Auto-trigger (skill)** — `.claude/skills/octospec-workflow/`. When a developer
  asks Claude Code to implement/fix/refactor something, the skill's description
  matches and Claude **runs the 4-phase flow automatically** — no command to
  remember. Trivial edits (typo/docs/lint/config) are skipped by design.
- **Manual control (slash commands)** — `.claude/commands/octospec-*`. Use these
  to drive a single phase on demand: `/octospec-plan`, `/octospec-go`,
  `/octospec-check`, `/octospec-finish`.

Both version with the repo, so everyone is always on the same workflow — nothing
to install, nothing to keep in sync by hand.

### Three levels of how the flow runs

| Level | Mechanism | Trigger | Strength |
|---|---|---|---|
| Auto | skill | model decides from your request | seamless, probabilistic |
| Manual | slash command | you type it | precise, opt-in |
| Enforce | PR template + (future) CI gate | merge time | deterministic |

The skill makes the flow *easy and automatic*; the PR/CI gate makes it *binding*.

## Setup (once per repo, by a maintainer)

1. Initialize the skeleton: copy `templates/octospec-init` to `.octospec/`
   (this carries `.claude/` and a `.github/PULL_REQUEST_TEMPLATE.md` inside
   `.octospec/`; step 3's sync materializes them to the repo root for you).
2. Pin the global version in `.octospec/manifest.yaml`.
3. Run `octospec-sync` (with `GLOBAL_SRC` pointing at a checkout of octo-spec
   at the pinned version). This pulls global rules into git-ignored
   `.octospec/_global/`, writes the octospec block into your agent files
   (`CLAUDE.md` / `AGENTS.md` / `GEMINI.md` / `QWEN.md`) between
   `<!-- octospec:begin -->` / `<!-- octospec:end -->` markers — the sync owns
   that region; everything outside it is yours. `CLAUDE.md` and `AGENTS.md` are
   the two default entry points — whichever is missing is created so both Claude
   Code and Codex get the block; `GEMINI.md` / `QWEN.md` are synced only when they
   already exist. Finally it **materializes the repo-root scaffolding** that
   tools only discover at the root: it copies `.octospec/.claude/` to `.claude/`
   (so Claude Code finds the slash commands and skill) and
   `.octospec/.github/PULL_REQUEST_TEMPLATE.md` to `.github/` (so GitHub applies
   the PR template). This is install-if-missing — any file you have already
   customized at the root is left untouched, and re-running is idempotent.
4. Commit (including the materialized root `.claude/` and `.github/`). From here,
   every team member just pulls.

## The loop

| Command | Does | Writes |
|---|---|---|
| `/octospec-plan <task>` | Draft a task brief (AI may seed it from existing code; you confirm). | `tasks/<slug>/brief.md` |
| `/octospec-go <slug>` | Read the brief, inject the rules whose `inject_when` matches, write code (no commit). | `tasks/<slug>/context.yaml` + injection fingerprint |
| `/octospec-check <slug>` | Check the diff against injected rules; run lint/type-check/tests; self-fix. | (validation only) |
| `/octospec-finish <slug>` | Final check, record a shared journal entry, stage learnings, open a PR (body pre-filled with Linked Spec + COMPREHENSION). | `journal/shared/<slug>.md`, `learnings/pending/<slug>.md` |

## Rule injection

A rule is injected when its `inject_when.paths` glob matches a touched file **or**
its `inject_when.touches` tag is declared in the brief's load-bearing list. There
is an injection budget: when exceeded, load-bearing rules win, then higher
`priority`; truncated rules contribute only a summary line. The set of injected
rules is recorded in `context.yaml` with a content fingerprint for auditability.

## Promotion (learnings → rules)

`/octospec-finish` drops candidate learnings into `learnings/pending/`. Promoting
one into `rules/` is a deliberate, reviewed PR — not an automatic write. This is
how the standard gets smarter over time without drifting silently.
