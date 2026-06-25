#!/usr/bin/env bash
set -euo pipefail

# ─── Unified Slide System — Consumer Upgrade ────────────────────────────────
# Upgrades an existing presentation repo to the latest theme version:
#   1. Bumps the `theme` submodule to the latest (or a given) major tag.
#   2. Updates the CI workflow's theme refs to match.
#   3. Refreshes the theme-managed npm scripts in package.json.
#
# Conservative by design: it never overwrites your linting/spell/commit config
# or your decks — only the submodule pin, the CI ref, and the build scripts.
#
# Usage (from the root of a presentation repo):
#   bash theme/scripts/upgrade.sh            # upgrade to the latest tag
#   bash theme/scripts/upgrade.sh v3         # upgrade to a specific tag
#
# Or without a checkout of the theme scripts:
#   bash <(curl -sL https://raw.githubusercontent.com/craftosphere/unified-slide-system/main/scripts/upgrade.sh)
# ─────────────────────────────────────────────────────────────────────────────

THEME_DIR="theme"

info()  { printf "\033[1;34m▸\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

REPO_ROOT="$(pwd)"

# ─── Preconditions ───────────────────────────────────────────────────────────

check_repo() {
  command -v git  >/dev/null 2>&1 || die "git is required."
  command -v node >/dev/null 2>&1 || die "node is required to update package.json."

  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "Not a git repository. Run this from the root of a presentation repo."
  [[ -f "$REPO_ROOT/package.json" ]] \
    || die "No package.json found. Run this from the root of a presentation repo."
  git -C "$REPO_ROOT" config --file .gitmodules --get "submodule.${THEME_DIR}.url" >/dev/null 2>&1 \
    || die "No '${THEME_DIR}' submodule found. Is this a Unified Slide System repo?"

  # Ensure the submodule is checked out (fresh clones may not have it).
  if [[ ! -e "$REPO_ROOT/$THEME_DIR/.git" ]]; then
    info "Initialising the ${THEME_DIR} submodule..."
    git -C "$REPO_ROOT" submodule update --init "$THEME_DIR"
  fi
  ok "Presentation repo detected"
}

# ─── Resolve the target tag ──────────────────────────────────────────────────

resolve_target() {
  info "Fetching theme tags..."
  # --force is required: a moved tag (e.g. a major tag fast-forwarded to a new
  # release) would otherwise be "rejected ... would clobber existing tag" and,
  # under `set -e`, abort the whole upgrade before anything happens.
  git -C "$THEME_DIR" fetch --tags --force --quiet origin

  if [[ -n "${1:-}" ]]; then
    TARGET="$1"
    git -C "$THEME_DIR" rev-parse --verify --quiet "refs/tags/${TARGET}^{commit}" >/dev/null \
      || die "Tag '${TARGET}' not found in the theme repo."
  else
    # Latest release tag by version order — majors (v2), minors (v2.1), and
    # patches (v2.1.0) all qualify; pre-release tags (v2.1.0rc1) are ignored.
    # Ascending sort + tail (not desc + head) avoids a SIGPIPE under pipefail.
    TARGET="$(git -C "$THEME_DIR" tag -l 'v*' --sort=v:refname \
      | grep -E '^v[0-9]+(\.[0-9]+)*$' | tail -n1)"
    [[ -n "$TARGET" ]] || die "Could not determine the latest theme tag."
  fi

  CURRENT="$(git -C "$THEME_DIR" describe --tags --always 2>/dev/null || echo "unknown")"
  info "Current theme: ${CURRENT}  →  target: ${TARGET}"
}

# ─── Apply the upgrade ───────────────────────────────────────────────────────

bump_submodule() {
  info "Pinning ${THEME_DIR} submodule to ${TARGET}..."
  git -C "$THEME_DIR" checkout --quiet "$TARGET" \
    || die "Failed to check out ${TARGET} in ${THEME_DIR} (local changes in the submodule?)."
  git -C "$REPO_ROOT" add "$THEME_DIR"
  ok "Theme submodule pinned to ${TARGET}"
}

update_ci_ref() {
  local ci=".github/workflows/build.yml"
  if [[ ! -f "$ci" ]]; then
    return 0
  fi
  # Update both the reusable-workflow ref (@vN) and the theme-ref input.
  sed -E -i.bak \
    -e "s#(unified-slide-system/\.github/workflows/build-presentation\.yml@)v[0-9]+#\1${TARGET}#" \
    -e "s#(theme-ref:[[:space:]]*)v[0-9]+#\1${TARGET}#" \
    "$ci"
  rm -f "${ci}.bak"
  git -C "$REPO_ROOT" add "$ci" 2>/dev/null || true
  ok "CI workflow theme ref set to ${TARGET}"
}

refresh_scripts() {
  info "Refreshing theme-managed npm scripts..."
  node - "$REPO_ROOT/package.json" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(path, "utf8"));
pkg.scripts = pkg.scripts || {};

// Theme-owned scripts. These are kept in sync on every upgrade; everything
// else in `scripts` (lint, husky, etc.) is left untouched.
const managed = {
  "build": "bash theme/scripts/build.sh",
  "build:clean": "bash theme/scripts/build.sh --clean",
  "build:html": "SKIP_PDF=1 bash theme/scripts/build.sh",
  "watch": "bash theme/scripts/watch.sh",
  "setup": "cd theme && npm install && npx playwright install chromium",
  "clean": "rm -rf ./build/ ./.staging/",
  "upgrade": "bash theme/scripts/upgrade.sh",
};

const changed = [];
for (const [k, v] of Object.entries(managed)) {
  if (pkg.scripts[k] !== v) {
    changed.push(pkg.scripts[k] === undefined ? `+ ${k}` : `~ ${k}`);
    pkg.scripts[k] = v;
  }
}

fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");
console.error(changed.length ? changed.join("\n") : "(scripts already current)");
NODE
  git -C "$REPO_ROOT" add package.json 2>/dev/null || true
  ok "npm scripts refreshed"
}

# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  ok "Upgraded to ${TARGET}."
  echo ""
  echo "  Review the staged changes, then:"
  echo "    git diff --staged"
  echo "    npm run setup        # if theme dependencies changed"
  echo "    npm run build:clean  # full rebuild on the new theme"
  echo "    git commit -m 'build: upgrade theme to ${TARGET}'"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  echo ""
  check_repo
  resolve_target "${1:-}"
  bump_submodule
  update_ci_ref
  refresh_scripts
  print_summary
}

main "$@"
