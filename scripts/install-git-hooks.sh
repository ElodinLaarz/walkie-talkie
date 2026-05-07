#!/bin/bash
# Installs an opt-in `pre-push` git hook that runs scripts/presubmit.sh
# before every `git push`. A failing presubmit aborts the push so a CI
# round-trip is not spent on a regression a local run would have caught.
#
# Idempotent: running this twice replaces the existing hook in place.
# Bypass: `git push --no-verify` skips the hook for genuine emergencies.
#
# Run once per clone:
#   bash scripts/install-git-hooks.sh

set -e

cd "$(dirname "$0")/.."

# Resolve the real hooks directory. Worktrees and core.hooksPath both
# move it away from .git/hooks; ask git rather than guessing. Force an
# absolute path so the result survives the `cd` above — without
# --path-format=absolute, linked worktrees can return a relative path
# that resolves against the current working directory. Requires
# git ≥ 2.31 (January 2021).
HOOKS_DIR="$(git rev-parse --path-format=absolute --git-path hooks)"

if [ ! -d "$HOOKS_DIR" ]; then
  mkdir -p "$HOOKS_DIR"
fi

HOOK="$HOOKS_DIR/pre-push"
MARKER="Auto-installed by scripts/install-git-hooks.sh"

# If a contributor already has their own pre-push hook (husky, lefthook,
# manual setup, etc.) silently overwriting it would lose their work.
# Back it up so they can merge in the presubmit step manually if they
# want both. Re-running the installer over an already-installed hook is
# fine — those carry the MARKER and get replaced in place.
if [ -f "$HOOK" ] && ! grep -qF "$MARKER" "$HOOK"; then
  BACKUP="$HOOK.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$HOOK" "$BACKUP"
  echo "Existing pre-push hook (not auto-installed) backed up to $BACKUP"
fi

cat > "$HOOK" <<'EOF'
#!/bin/bash
# Auto-installed by scripts/install-git-hooks.sh. Runs the local CI mirror
# before every push; bypass with `git push --no-verify` if you need to
# push a partial branch (and accept the CI round-trip).
set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
PRESUBMIT="$REPO_ROOT/scripts/presubmit.sh"

if [ ! -f "$PRESUBMIT" ]; then
  echo "pre-push: $PRESUBMIT not found, skipping local CI." >&2
  exit 0
fi

echo "pre-push: running scripts/presubmit.sh (use 'git push --no-verify' to skip)"
bash "$PRESUBMIT"
EOF

chmod +x "$HOOK"

echo "Installed pre-push hook at $HOOK"
echo "Bypass with: git push --no-verify"
