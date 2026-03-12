#!/usr/bin/env bash
set -euo pipefail

# ─── Unified Slide System — Presentation Bootstrap ──────────────────────────
# Creates a new presentation repo with all infrastructure pre-configured:
# theme submodule, build pipeline, linting, commit hooks, and CI/CD.
#
# Usage (without cloning the theme repo):
#   bash <(curl -sL https://raw.githubusercontent.com/craftosphere/unified-slide-system/main/scripts/bootstrap.sh)
# ─────────────────────────────────────────────────────────────────────────────

THEME_REPO="https://github.com/craftosphere/unified-slide-system.git"
NODE_VERSION="20"
BRANDS=(brix craftosphere dojo)

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()  { printf "\033[1;34m▸\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m✓\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
error() { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

# Prompt with a default value. Empty input accepts the default.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    printf "\033[1m%s\033[0m [%s]: " "$prompt" "$default" >&2
  else
    printf "\033[1m%s\033[0m: " "$prompt" >&2
  fi
  read -r reply
  echo "${reply:-$default}"
}

# Yes/no prompt. Returns 0 for yes, 1 for no.
confirm() {
  local prompt="$1" default="${2:-y}" reply
  if [[ "$default" == "y" ]]; then
    printf "\033[1m%s\033[0m [Y/n]: " "$prompt"
  else
    printf "\033[1m%s\033[0m [y/N]: " "$prompt"
  fi
  read -r reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# Slugify a string: lowercase, spaces/underscores to hyphens, strip non-alnum.
slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' _' '-' | sed 's/[^a-z0-9-]//g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# ─── Prerequisite checks ────────────────────────────────────────────────────

check_prerequisites() {
  local missing=()

  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v node >/dev/null 2>&1 || missing+=("node")
  command -v npm >/dev/null 2>&1 || missing+=("npm")

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}. Please install them and try again."
  fi

  # Check Node version
  local node_major
  node_major=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$node_major" -lt "$NODE_VERSION" ]]; then
    die "Node.js $NODE_VERSION+ is required (found v$(node -v | sed 's/v//')). Please upgrade."
  fi

  ok "Prerequisites OK (git, node v${node_major}, npm)"
}

check_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    die "GitHub CLI (gh) is required for remote repos. Install it from https://cli.github.com"
  fi
  if ! gh auth status >/dev/null 2>&1; then
    die "GitHub CLI is not authenticated. Run 'gh auth login' first."
  fi
  ok "GitHub CLI authenticated"
}

# ─── User input ─────────────────────────────────────────────────────────────

collect_input() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Unified Slide System — New Presentation"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # 1. Presentation title
  while [[ -z "${TITLE:-}" ]]; do
    TITLE=$(ask "Presentation title")
    [[ -z "$TITLE" ]] && warn "Title is required."
  done

  # 2. Repo name
  local default_slug
  default_slug=$(slugify "$TITLE")
  REPO_NAME=$(ask "Repo name (directory name)" "$default_slug")
  REPO_NAME=$(slugify "$REPO_NAME")

  if [[ -d "$REPO_NAME" ]]; then
    die "Directory '$REPO_NAME' already exists."
  fi

  # 3. Default brand
  echo ""
  info "Available brands: ${BRANDS[*]}"
  DEFAULT_BRAND=$(ask "Default brand" "craftosphere")

  local valid_brand=false
  for b in "${BRANDS[@]}"; do
    [[ "$b" == "$DEFAULT_BRAND" ]] && valid_brand=true
  done
  if [[ "$valid_brand" == false ]]; then
    die "Unknown brand '$DEFAULT_BRAND'. Must be one of: ${BRANDS[*]}"
  fi

  # 4. Remote repo?
  echo ""
  if confirm "Create a remote GitHub repo?"; then
    CREATE_REMOTE=true
    check_gh

    # 5. GitHub owner/org
    local default_owner
    default_owner=$(gh api user -q .login 2>/dev/null || echo "")
    REPO_OWNER=$(ask "GitHub owner/org" "$default_owner")

    # 6. Visibility
    if confirm "Make the repo public?" "n"; then
      REPO_VISIBILITY="public"
    else
      REPO_VISIBILITY="private"
    fi

    # 7. Description
    local default_desc="${TITLE} — a Marp presentation built with the Unified Slide System"
    REPO_DESCRIPTION=$(ask "Repo description" "$default_desc")
  else
    CREATE_REMOTE=false
  fi

  # Summary
  echo ""
  echo "──────────────────────────────────────────────────────────────────────────────"
  info "Title:         $TITLE"
  info "Repo:          $REPO_NAME"
  info "Default brand: $DEFAULT_BRAND"
  if [[ "$CREATE_REMOTE" == true ]]; then
    info "Remote:        $REPO_OWNER/$REPO_NAME ($REPO_VISIBILITY)"
    info "Description:   $REPO_DESCRIPTION"
  else
    info "Remote:        local only"
  fi
  echo "──────────────────────────────────────────────────────────────────────────────"
  echo ""

  if ! confirm "Proceed?"; then
    die "Aborted."
  fi
}

# ─── Repo creation ──────────────────────────────────────────────────────────

create_repo() {
  if [[ "$CREATE_REMOTE" == true ]]; then
    info "Creating remote repo $REPO_OWNER/$REPO_NAME..."
    gh repo create "$REPO_OWNER/$REPO_NAME" \
      --"$REPO_VISIBILITY" \
      --description "$REPO_DESCRIPTION" \
      --clone
    cd "$REPO_NAME"
  else
    info "Creating local repo $REPO_NAME..."
    mkdir -p "$REPO_NAME"
    cd "$REPO_NAME"
    git init
  fi

  ok "Repo created at $(pwd)"
}

# ─── Theme submodule ────────────────────────────────────────────────────────

add_submodule() {
  info "Adding theme submodule..."
  git submodule add "$THEME_REPO" theme
  ok "Theme submodule added"
}

# ─── File scaffolding ───────────────────────────────────────────────────────

write_gitignore() {
  cat > .gitignore << 'EOF'
.DS_Store

build/
node_modules/
.staging/
EOF
}

write_package_json() {
  cat > package.json << EOF
{
  "name": "${REPO_NAME}",
  "version": "1.0.0",
  "description": "${REPO_DESCRIPTION:-${TITLE}}",
  "scripts": {
    "build": "bash theme/scripts/build.sh",
    "build:html": "SKIP_PDF=1 bash theme/scripts/build.sh",
    "watch": "bash theme/scripts/watch.sh",
    "setup": "cd theme && npm install && npx playwright install chromium",
    "clean": "rm -rf ./build/ ./.staging/",
    "lint": "npm run lint:md && npm run lint:spell",
    "lint:md": "markdownlint-cli2 '**/*.md'",
    "lint:file:md": "markdownlint-cli2",
    "lint:spell": "cspell '**/*.md'",
    "lint:file:spell": "cspell",
    "prepare": "husky",
    "precommit": "lint-staged --relative --verbose"
  },
  "lint-staged": {
    "*.{md}": [
      "npm run lint:file:md",
      "npm run lint:file:spell"
    ],
    "package.json": [
      "sort-package-json"
    ]
  },
  "devDependencies": {
    "@commitlint/config-conventional": "^20.4.3",
    "commitlint": "^20.4.3",
    "cspell": "^8.0.0",
    "husky": "^9.0.0",
    "lint-staged": "^16.3.3",
    "markdownlint-cli2": "^0.17.0",
    "sort-package-json": "^3.6.1"
  }
}
EOF
}

write_markdownlint_config() {
  cat > .markdownlint-cli2.jsonc << 'EOF'
{
  "config": {
    // Allow HTML in Marp slides (directives, footer, divs)
    "MD033": false,
    // Allow inline HTML attributes
    "MD013": false,
    // Allow duplicate headings across slides
    "MD024": false,
    // Allow headings without content (section dividers)
    "MD025": false,
    // Ban only the following trailing punctuation in headings
    "MD026": { "punctuation": ".,;:" },
    // Allow starting ordered lists with any number
    "MD029": false,
    // Allow multiple top-level headings (each slide can have an h1)
    "MD041": false,
    // Allow blank lines around HTML blocks
    "MD014": false
  },
  "customRules": ["./theme/mdlint-rules/titlecase.js"],
  "ignores": [
    "node_modules",
    "theme/**",
    "build/**",
    ".staging/**"
  ]
}
EOF
}

write_cspell_config() {
  cat > cspell.json << 'EOF'
{
  "version": "0.2",
  "language": "en",
  "ignorePaths": [
    "node_modules",
    "theme/**",
    "build/**",
    ".staging/**",
    "package*.json"
  ],
  "words": [
    "Marp",
    "marp",
    "Craftosphere",
    "craftosphere",
    "BriX",
    "brix",
    "Dojo",
    "dojo",
    "paginate",
    "frontmatter",
    "Fira",
    "Lato"
  ],
  "dictionaries": ["en-gb", "en-us"],
  "allowCompoundWords": true
}
EOF
}

write_commitlint_config() {
  cat > commitlint.config.mjs << 'COMMITLINT'
const ERROR = 2;
const WARNING = 1;

export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [
      ERROR,
      'always',
      [
        'build',
        'chore',
        'ci',
        'docs',
        'feat',
        'fix',
        'init',
        'perf',
        'refactor',
        'revert',
        'style',
        'test',
      ],
    ],
    'body-max-line-length': [WARNING, 'always', 100],
  },
};
COMMITLINT
}

write_ci_workflow() {
  [[ "$CREATE_REMOTE" == true ]] || return 0

  mkdir -p .github/workflows
  cat > .github/workflows/build.yml << 'EOF'
name: Build Presentation

on:
  push:
    branches: [main]
    tags: ["**"]
  pull_request:
  workflow_dispatch:

jobs:
  build:
    uses: craftosphere/unified-slide-system/.github/workflows/build-presentation.yml@v1
    permissions:
      contents: write
    with:
      theme-ref: v1
EOF
}

write_presentation() {
  local brand="$DEFAULT_BRAND"

  cat > presentation.md << EOF
---
marp: true
theme: ${brand}
paginate: true
footer: '<img src="./assets/${brand}-logo.svg" class="logo"><img src="./assets/${brand}-logo-light.svg" class="logo-light">'
---

<!-- _class: title-logo -->

# ${TITLE}

---

## Agenda

- Topic one
- Topic two
- Topic three

<!--
Speaker notes go here.
Only visible in presenter view.
-->

---

## Two-Column Layout

<!-- _class: cols-6-6 -->

## Two-Column Layout

<div>

### Left Column

Content on the left side.

</div>

<div>

### Right Column

Content on the right side.

</div>

---

<!-- _class: title -->

# Thank You
EOF
}

write_readme() {
  local clone_cmd=""
  if [[ "$CREATE_REMOTE" == true ]]; then
    clone_cmd="git clone --recurse-submodules https://github.com/${REPO_OWNER}/${REPO_NAME}.git
cd ${REPO_NAME}"
  else
    clone_cmd="cd ${REPO_NAME}"
  fi

  local badge=""
  local ci_section=""
  if [[ "$CREATE_REMOTE" == true ]]; then
    badge="

[![Build](https://github.com/${REPO_OWNER}/${REPO_NAME}/actions/workflows/build.yml/badge.svg)](https://github.com/${REPO_OWNER}/${REPO_NAME}/actions/workflows/build.yml)"
    if [[ "$REPO_VISIBILITY" == "public" ]]; then
      badge+="
[![Release](https://img.shields.io/github/v/release/${REPO_OWNER}/${REPO_NAME}?label=release)](https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest)"
    fi
    ci_section="

## CI/CD

Pushes to \`main\` and pull requests trigger the build pipeline (lint + build all brands). Pushing a tag also creates a GitHub Release with per-brand zips attached.

See the [theme CI/CD docs](https://github.com/craftosphere/unified-slide-system/blob/main/CICD.md) for details."
  fi

  cat > README.md << EOF
# ${TITLE}${badge}

A [Marp](https://marp.app) presentation built with the [Unified Slide System](https://github.com/craftosphere/unified-slide-system).

## Quick Start

\`\`\`bash
${clone_cmd}
npm install
npm run setup
npm run build
\`\`\`

Output is in \`build/{brand}/\` — one subfolder per brand, each containing an HTML and PDF version.

## Commands

| Command              | Description                                        |
| -------------------- | -------------------------------------------------- |
| \`npm run setup\`      | Install theme dependencies and Playwright Chromium |
| \`npm run build\`      | Build all brands as HTML + PDF                     |
| \`npm run build:html\` | Build all brands as HTML only (faster, no browser) |
| \`npm run watch\`      | Start dev server with live reload (default brand)  |
| \`npm run clean\`      | Remove build and staging directories               |
| \`npm run lint\`       | Run Markdown lint and spell check                  |

To preview a specific brand in watch mode: \`BRAND=brix npm run watch\`.

## Assets

All image paths in the Markdown use \`./assets/\`. The build system merges two directories into that namespace:

- **\`theme/assets/\`** — Brand logos, shared across all presentations. Managed by the theme.
- **\`assets/\`** — Presentation-specific images (QR codes, photos). Managed here.

Both are available at build time and in watch mode. If a filename exists in both, the project file takes precedence.

## Frontmatter

Every deck starts with a YAML frontmatter block:

\`\`\`yaml
---
marp: true
theme: ${DEFAULT_BRAND}
paginate: true
footer: '<img src="./assets/${DEFAULT_BRAND}-logo.svg" class="logo"><img src="./assets/${DEFAULT_BRAND}-logo-light.svg" class="logo-light">'
---
\`\`\`

Change \`theme:\` to switch brands. The build script handles logo filename swapping automatically.${ci_section}
EOF
}

# ─── Install and hooks ──────────────────────────────────────────────────────

install_dependencies() {
  info "Installing dependencies..."
  npm install --no-audit --no-fund
  ok "Dependencies installed"

  info "Installing theme dependencies and Playwright Chromium..."
  npm run setup
  ok "Theme setup complete"
}

setup_hooks() {
  info "Setting up git hooks..."

  mkdir -p .husky

  cat > .husky/commit-msg << 'EOF'
npx --no-install commitlint --edit "$1"
EOF
  chmod +x .husky/commit-msg

  cat > .husky/pre-push << 'EOF'
npm run lint
EOF
  chmod +x .husky/pre-push

  ok "Git hooks configured (commit-msg, pre-push)"
}

# ─── Lint, commit, and push ──────────────────────────────────────────────────

run_lint() {
  info "Running lint checks..."
  if npm run lint; then
    ok "Lint passed"
    return 0
  else
    warn "Lint failed — skipping commit and push."
    warn "Fix the issues above, then run: git add -A && git commit -m 'init: scaffold presentation repo' && git push"
    return 1
  fi
}

initial_commit() {
  info "Creating initial commit..."
  git add -A
  git commit -m "init: scaffold presentation repo

Bootstrapped with the Unified Slide System.
Theme: ${DEFAULT_BRAND}
$(if [[ "$CREATE_REMOTE" == true ]]; then echo "CI/CD: enabled"; else echo "CI/CD: local only"; fi)"
  ok "Initial commit created"
}

push_to_remote() {
  [[ "$CREATE_REMOTE" == true ]] || return 0

  info "Pushing to remote..."
  git push -u origin main
  ok "Pushed to origin/main"
}

# ─── Summary ────────────────────────────────────────────────────────────────

print_summary() {
  local lint_ok="${1:-true}"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$lint_ok" == true ]]; then
    ok "Presentation repo ready!"
  else
    warn "Presentation repo created, but lint failed — not committed or pushed."
  fi
  echo ""
  info "Location: $(pwd)"
  if [[ "$CREATE_REMOTE" == true && "$lint_ok" == true ]]; then
    info "Remote:   https://github.com/${REPO_OWNER}/${REPO_NAME}"
  fi
  echo ""
  if [[ "$lint_ok" == false ]]; then
    echo "  Fix lint errors, then:"
    echo "    git add -A"
    echo "    git commit -m 'init: scaffold presentation repo'"
    [[ "$CREATE_REMOTE" == true ]] && echo "    git push -u origin main"
    echo ""
  fi
  echo "  Next steps:"
  echo "    cd ${REPO_NAME}"
  echo "    npm run watch          # start dev server"
  echo "    npm run build          # build all brands"
  echo ""
  echo "  Edit presentation.md to write your slides."
  echo "  Put images in assets/."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  echo ""
  check_prerequisites
  collect_input

  create_repo
  add_submodule

  info "Scaffolding files..."
  write_gitignore
  write_package_json
  write_markdownlint_config
  write_cspell_config
  write_commitlint_config
  write_ci_workflow
  write_presentation
  write_readme
  ok "Files created"

  install_dependencies
  setup_hooks

  local lint_ok=true
  if ! run_lint; then
    lint_ok=false
  fi

  if [[ "$lint_ok" == true ]]; then
    initial_commit
    push_to_remote
  fi

  print_summary "$lint_ok"
}

main
