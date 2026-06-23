#!/usr/bin/env bash
# Regression test for octospec-sync.sh's exit-code propagation.
# A refused (malformed-marker) agent file must make the whole sync exit non-zero,
# even though per-file isolation lets the other files sync. (PR #3 review: caller
# was swallowing the failure and exiting 0.)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
fail=0

note() { printf '%s - %s\n' "$1" "$2"; }

# Build a throwaway repo with a healthy CLAUDE.md and a corrupted AGENTS.md.
# All temp dirs register with a single cleanup trap so an early `set -e` exit (or
# a mid-test failure) never leaves throwaway repos behind.
TMP_DIRS=()
cleanup() { for d in "${TMP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT
tmp="$(mktemp -d)"; TMP_DIRS+=("$tmp")
cd "$tmp"
git init -q
mkdir -p .octospec
printf 'inherits: octo-spec@1.2.0\n' > .octospec/manifest.yaml
printf '# CLAUDE\n\nteam rule\n' > CLAUDE.md
# orphan begin marker -> the python helper must REFUSE this file
printf '# AGENTS\n\n<!-- octospec:begin -->\nrule beta KEEP ME\n' > AGENTS.md

set +e
GLOBAL_SRC="$REPO" bash "$REPO/scripts/octospec-sync.sh" > out.log 2>&1
code=$?
set -e

if [ "$code" -ne 0 ]; then
  note ok "sync exits non-zero when an agent file is refused (code=$code)"
else
  note FAIL "sync exited 0 despite a refused file"; fail=1
fi

if grep -q "rule beta KEEP ME" AGENTS.md; then
  note ok "refused AGENTS.md left untouched (content preserved)"
else
  note FAIL "refused AGENTS.md lost content"; fail=1
fi

if grep -q "octospec:begin" CLAUDE.md && grep -q "team rule" CLAUDE.md; then
  note ok "healthy CLAUDE.md still synced (per-file isolation kept)"
else
  note FAIL "healthy CLAUDE.md not synced"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "shell-wrapper exit-code test: PASS"
else
  echo "shell-wrapper exit-code test: FAIL"
fi

# ---------------------------------------------------------------------------
# Bootstrap regression: a repo that starts with ONLY CLAUDE.md (the common
# initial state of an existing Claude Code repo) must still get AGENTS.md
# created, so Codex — which reads AGENTS.md — receives the octospec block.
# (PR #3 review: the old any_present bootstrap skipped AGENTS.md whenever any
# candidate already existed, so a CLAUDE.md-only repo silently never got it.)
tmp2="$(mktemp -d)"; TMP_DIRS+=("$tmp2")
cd "$tmp2"
git init -q
mkdir -p .octospec
printf 'inherits: octo-spec@1.2.0\n' > .octospec/manifest.yaml
printf '# CLAUDE\n\nteam rule keep me\n' > CLAUDE.md
# Intentionally NO AGENTS.md / GEMINI.md / QWEN.md.

set +e
GLOBAL_SRC="$REPO" bash "$REPO/scripts/octospec-sync.sh" > out.log 2>&1
code2=$?
set -e

if [ "$code2" -eq 0 ]; then
  note ok "sync of a CLAUDE.md-only repo exits 0"
else
  note FAIL "sync of a CLAUDE.md-only repo exited $code2"; fail=1
  cat out.log
fi

if [ -f AGENTS.md ]; then
  note ok "AGENTS.md created in a CLAUDE.md-only repo"
else
  note FAIL "AGENTS.md NOT created in a CLAUDE.md-only repo"; fail=1
fi

if grep -q "octospec:begin" AGENTS.md 2>/dev/null && grep -q "octospec:end" AGENTS.md 2>/dev/null; then
  note ok "bootstrapped AGENTS.md contains the octospec marker block"
else
  note FAIL "bootstrapped AGENTS.md missing octospec marker block"; fail=1
fi

if grep -q "octospec:begin" CLAUDE.md && grep -q "team rule keep me" CLAUDE.md; then
  note ok "existing CLAUDE.md still synced, no data loss"
else
  note FAIL "existing CLAUDE.md not synced or lost content"; fail=1
fi

# GEMINI.md / QWEN.md must NOT be force-created.
if [ ! -e GEMINI.md ] && [ ! -e QWEN.md ]; then
  note ok "GEMINI.md/QWEN.md not force-created (only-existing behavior kept)"
else
  note FAIL "GEMINI.md/QWEN.md were force-created"; fail=1
fi

rm -rf "$tmp2"

if [ "$fail" -eq 0 ]; then
  echo "shell-wrapper bootstrap test: PASS"
else
  echo "shell-wrapper bootstrap test: FAIL"
fi

# ---------------------------------------------------------------------------
# Template drift guard: the quickstart (README) tells users to copy
# templates/octospec-init -> .octospec and then run
# ./.octospec/scripts/octospec-sync.sh. That only works if the template ships a
# scripts/ dir, and those copies MUST stay byte-identical to the canonical
# scripts/ originals — otherwise the vendored copy silently drifts from the
# tested source. (PR #3 收口: template had no scripts/ at all, so the documented
# init failed with "no such file or directory".)
TPL="$REPO/templates/octospec-init/scripts"
for f in octospec-sync.sh octospec_sync_block.py; do
  if [ ! -f "$TPL/$f" ]; then
    note FAIL "template missing scripts/$f (quickstart would break)"; fail=1
  elif ! cmp -s "$REPO/scripts/$f" "$TPL/$f"; then
    note FAIL "template scripts/$f drifted from canonical scripts/$f"; fail=1
  else
    note ok "template scripts/$f present and identical to canonical"
  fi
done

# ---------------------------------------------------------------------------
# Quickstart end-to-end: reproduce the documented README quickstart verbatim in
# a fresh temp repo — copy the template to .octospec, then run the vendored
# script by its documented relative path. Must succeed and produce a synced
# CLAUDE.md, with no "no such file" failure.
tmp3="$(mktemp -d)"; TMP_DIRS+=("$tmp3")
cd "$tmp3"
git init -q
cp -r "$REPO/templates/octospec-init" .octospec

set +e
out="$(GLOBAL_SRC="$REPO" ./.octospec/scripts/octospec-sync.sh 2>&1)"
code3=$?
set -e

if [ "$code3" -eq 0 ]; then
  note ok "quickstart (cp template + run vendored script) exits 0"
else
  note FAIL "quickstart failed (code=$code3)"; fail=1
  printf '%s\n' "$out"
fi

if printf '%s' "$out" | grep -qi "no such file"; then
  note FAIL "quickstart hit a 'no such file' error"; fail=1
fi

if grep -q "octospec:begin" CLAUDE.md 2>/dev/null && grep -q "octospec:end" CLAUDE.md 2>/dev/null; then
  note ok "quickstart synced the octospec block into CLAUDE.md"
else
  note FAIL "quickstart did not sync CLAUDE.md"; fail=1
fi

cd "$REPO"
rm -rf "$tmp3"

if [ "$fail" -eq 0 ]; then
  echo "quickstart end-to-end test: PASS"
else
  echo "quickstart end-to-end test: FAIL"
fi

# ---------------------------------------------------------------------------
# Version assertion (YUJ-5344): the manifest pin (inherits: octo-spec@X) must
# match the GLOBAL_SRC checkout's VERSION, asserted BEFORE any vendoring so a
# stale pin never silently ships the wrong global rules. GLOBAL_SRC=$REPO has
# VERSION=1.2.0, so the fixtures pin 1.2.0 on the happy path.

# [api] 1) pin == VERSION -> exit 0, block synced, and re-running is idempotent.
tmp4="$(mktemp -d)"; TMP_DIRS+=("$tmp4")
cd "$tmp4"
git init -q
mkdir -p .octospec
printf 'inherits: octo-spec@1.2.0\n' > .octospec/manifest.yaml
printf '# CLAUDE\n\nteam rule\n' > CLAUDE.md

set +e
GLOBAL_SRC="$REPO" bash "$REPO/scripts/octospec-sync.sh" > out.log 2>&1
code4=$?
set -e

if [ "$code4" -eq 0 ]; then
  note ok "version-match sync exits 0 (pin 1.2.0 == VERSION 1.2.0)"
else
  note FAIL "version-match sync exited $code4"; fail=1
  cat out.log
fi

if grep -q "octospec:begin" CLAUDE.md; then
  note ok "version-match sync wrote the octospec block"
else
  note FAIL "version-match sync did not write the octospec block"; fail=1
fi

first="$(cat CLAUDE.md)"
set +e
GLOBAL_SRC="$REPO" bash "$REPO/scripts/octospec-sync.sh" > out.log 2>&1
code4b=$?
set -e
if [ "$code4b" -eq 0 ] && [ "$first" = "$(cat CLAUDE.md)" ]; then
  note ok "version-match sync is idempotent (second run unchanged)"
else
  note FAIL "version-match sync not idempotent (code=$code4b)"; fail=1
fi

cd "$REPO"

# [api] 2) pin != VERSION -> non-zero, VERSION MISMATCH, NOTHING vendored/rewritten.
tmp5="$(mktemp -d)"; TMP_DIRS+=("$tmp5")
cd "$tmp5"
git init -q
mkdir -p .octospec
printf 'inherits: octo-spec@9.9.9\n' > .octospec/manifest.yaml
printf '# CLAUDE\n\noriginal team rule\n' > CLAUDE.md

set +e
out5="$(GLOBAL_SRC="$REPO" bash "$REPO/scripts/octospec-sync.sh" 2>&1)"
code5=$?
set -e

if [ "$code5" -ne 0 ]; then
  note ok "version-mismatch sync exits non-zero (code=$code5)"
else
  note FAIL "version-mismatch sync exited 0"; fail=1
fi

if printf '%s' "$out5" | grep -q "VERSION MISMATCH"; then
  note ok "version-mismatch stderr contains VERSION MISMATCH"
else
  note FAIL "version-mismatch stderr missing VERSION MISMATCH"; fail=1
  printf '%s\n' "$out5"
fi

if [ ! -e .octospec/_global ]; then
  note ok "version-mismatch aborted before vendoring (_global not created)"
else
  note FAIL "version-mismatch vendored _global despite mismatch"; fail=1
fi

if [ "$(cat CLAUDE.md)" = "$(printf '# CLAUDE\n\noriginal team rule\n')" ]; then
  note ok "version-mismatch left CLAUDE.md untouched (no rewrite before assert)"
else
  note FAIL "version-mismatch rewrote CLAUDE.md before asserting"; fail=1
fi

cd "$REPO"

# [api] 3) escape hatch: pin != VERSION + OCTOSPEC_SKIP_VERSION_CHECK=1 -> exit 0.
tmp6="$(mktemp -d)"; TMP_DIRS+=("$tmp6")
cd "$tmp6"
git init -q
mkdir -p .octospec
printf 'inherits: octo-spec@9.9.9\n' > .octospec/manifest.yaml
printf '# CLAUDE\n\nteam rule\n' > CLAUDE.md

set +e
OCTOSPEC_SKIP_VERSION_CHECK=1 GLOBAL_SRC="$REPO" bash "$REPO/scripts/octospec-sync.sh" > out.log 2>&1
code6=$?
set -e

if [ "$code6" -eq 0 ]; then
  note ok "escape hatch (SKIP_VERSION_CHECK=1) bypasses mismatch, exits 0"
else
  note FAIL "escape hatch did not bypass mismatch (code=$code6)"; fail=1
  cat out.log
fi

if grep -q "octospec:begin" CLAUDE.md; then
  note ok "escape hatch still vendors + syncs the block"
else
  note FAIL "escape hatch did not sync the block"; fail=1
fi

cd "$REPO"

# [api] 4) boundary: GLOBAL_SRC without a VERSION file -> non-zero, "no VERSION file".
tmp7="$(mktemp -d)"; TMP_DIRS+=("$tmp7")
nover="$(mktemp -d)"; TMP_DIRS+=("$nover")   # GLOBAL_SRC dir with NO VERSION file
mkdir -p "$nover/global"
cd "$tmp7"
git init -q
mkdir -p .octospec
printf 'inherits: octo-spec@1.2.0\n' > .octospec/manifest.yaml
printf '# CLAUDE\n\nteam rule\n' > CLAUDE.md

set +e
out7="$(GLOBAL_SRC="$nover" bash "$REPO/scripts/octospec-sync.sh" 2>&1)"
code7=$?
set -e

if [ "$code7" -ne 0 ]; then
  note ok "missing-VERSION-file sync exits non-zero (code=$code7)"
else
  note FAIL "missing-VERSION-file sync exited 0"; fail=1
fi

if printf '%s' "$out7" | grep -q "no VERSION file"; then
  note ok "missing-VERSION-file stderr contains 'no VERSION file'"
else
  note FAIL "missing-VERSION-file stderr missing 'no VERSION file'"; fail=1
  printf '%s\n' "$out7"
fi

cd "$REPO"

if [ "$fail" -eq 0 ]; then
  echo "version-assertion test: PASS"
else
  echo "version-assertion test: FAIL"
fi

# ---------------------------------------------------------------------------
# Root scaffolding materialization (YUJ-5579 GAP-2/GAP-3): the template tree
# carries .octospec/.claude/ (slash commands + skills) and
# .octospec/.github/PULL_REQUEST_TEMPLATE.md, but Claude Code only discovers
# slash commands/skills under the REPO ROOT .claude/ and GitHub only applies a
# PR template at the REPO ROOT .github/. Sync must materialize those out of
# .octospec/ to the root, install-if-missing (never clobber user edits), and be
# idempotent. Reproduce the documented quickstart (cp template -> .octospec).
tmp8="$(mktemp -d)"; TMP_DIRS+=("$tmp8")
cd "$tmp8"
git init -q
cp -r "$REPO/templates/octospec-init" .octospec

set +e
GLOBAL_SRC="$REPO" ./.octospec/scripts/octospec-sync.sh > out.log 2>&1
code8=$?
set -e

if [ "$code8" -eq 0 ]; then
  note ok "root-scaffolding sync exits 0"
else
  note FAIL "root-scaffolding sync exited $code8"; fail=1
  cat out.log
fi

# GAP-2: slash commands discoverable at the repo root.
if [ -f .claude/commands/octospec-plan.md ] \
   && [ -f .claude/commands/octospec-go.md ] \
   && [ -f .claude/commands/octospec-check.md ] \
   && [ -f .claude/commands/octospec-finish.md ]; then
  note ok "slash commands materialized to repo-root .claude/commands/"
else
  note FAIL "repo-root .claude/commands/octospec-* missing after sync"; fail=1
fi

# GAP-2: workflow skill discoverable at the repo root too.
if [ -f .claude/skills/octospec-workflow/SKILL.md ]; then
  note ok "workflow skill materialized to repo-root .claude/skills/"
else
  note FAIL "repo-root .claude/skills/ missing after sync"; fail=1
fi

# GAP-3: PR template installed at the repo root where GitHub looks for it.
if [ -f .github/PULL_REQUEST_TEMPLATE.md ]; then
  note ok "PR template materialized to repo-root .github/PULL_REQUEST_TEMPLATE.md"
else
  note FAIL "repo-root .github/PULL_REQUEST_TEMPLATE.md missing after sync"; fail=1
fi

# GAP-3: the installed PR template matches the canonical source (no drift).
if cmp -s "$REPO/templates/PULL_REQUEST_TEMPLATE.md" .github/PULL_REQUEST_TEMPLATE.md; then
  note ok "installed PR template matches canonical templates/PULL_REQUEST_TEMPLATE.md"
else
  note FAIL "installed PR template differs from canonical source"; fail=1
fi

# Idempotency: a second run installs nothing new and still exits 0.
before_claude="$(find .claude -type f | sort | xargs -I{} md5sum {} 2>/dev/null)"
before_prt="$(md5sum .github/PULL_REQUEST_TEMPLATE.md)"
set +e
GLOBAL_SRC="$REPO" ./.octospec/scripts/octospec-sync.sh > out2.log 2>&1
code8b=$?
set -e
after_claude="$(find .claude -type f | sort | xargs -I{} md5sum {} 2>/dev/null)"
after_prt="$(md5sum .github/PULL_REQUEST_TEMPLATE.md)"
if [ "$code8b" -eq 0 ] && [ "$before_claude" = "$after_claude" ] && [ "$before_prt" = "$after_prt" ]; then
  note ok "root-scaffolding sync is idempotent (second run changes nothing)"
else
  note FAIL "root-scaffolding sync not idempotent (code=$code8b)"; fail=1
fi
if grep -q "kept 6 existing" out2.log && grep -q "PULL_REQUEST_TEMPLATE.md -> kept existing" out2.log; then
  note ok "idempotent second run reports existing files kept"
else
  note FAIL "second run did not report kept-existing scaffolding"; fail=1
fi

cd "$REPO"

# No-clobber: a user's own slash command + PR template survive sync, while
# missing siblings are still installed.
tmp9="$(mktemp -d)"; TMP_DIRS+=("$tmp9")
cd "$tmp9"
git init -q
cp -r "$REPO/templates/octospec-init" .octospec
mkdir -p .claude/commands .github
printf 'MY CUSTOM PLAN KEEP ME\n' > .claude/commands/octospec-plan.md
printf 'MY OWN PR TEMPLATE KEEP ME\n' > .github/PULL_REQUEST_TEMPLATE.md

set +e
GLOBAL_SRC="$REPO" ./.octospec/scripts/octospec-sync.sh > out.log 2>&1
code9=$?
set -e

if [ "$code9" -eq 0 ]; then
  note ok "no-clobber sync exits 0"
else
  note FAIL "no-clobber sync exited $code9"; fail=1
  cat out.log
fi

if grep -q "MY CUSTOM PLAN KEEP ME" .claude/commands/octospec-plan.md; then
  note ok "user's customized slash command left untouched"
else
  note FAIL "sync clobbered a user-customized slash command"; fail=1
fi

if grep -q "MY OWN PR TEMPLATE KEEP ME" .github/PULL_REQUEST_TEMPLATE.md; then
  note ok "user's own PR template left untouched"
else
  note FAIL "sync clobbered a user-owned PR template"; fail=1
fi

if [ -f .claude/commands/octospec-go.md ] && [ -f .claude/commands/octospec-finish.md ]; then
  note ok "missing slash commands still installed alongside the user's own"
else
  note FAIL "sync skipped installing missing slash commands"; fail=1
fi

cd "$REPO"

if [ "$fail" -eq 0 ]; then
  echo "root-scaffolding materialization test: PASS"
else
  echo "root-scaffolding materialization test: FAIL"
fi
exit "$fail"
