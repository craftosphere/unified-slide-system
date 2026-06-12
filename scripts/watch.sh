#!/usr/bin/env bash
set -euo pipefail

# ─── Dev server with live reload ──────────────────────────────────────────────
# Serves the decks under src/ (or a subdirectory passed as the first argument)
# with live reload. Each deck declares its own brand/size/layout in front
# matter — there is no brand staging. Usage:
#   bash theme/scripts/watch.sh            # serve all of src/
#   bash theme/scripts/watch.sh src/linkedin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(pwd)"

SRC_DIR="${PROJECT_ROOT}/src"
THEMES_DIR="${THEME_ROOT}/themes"
THEME_ASSETS_DIR="${THEME_ROOT}/assets"
PROJECT_ASSETS_DIR="${PROJECT_ROOT}/assets"

MARP_BIN="${THEME_ROOT}/node_modules/.bin/marp"
if [[ ! -x "$MARP_BIN" ]]; then
  echo "Marp CLI not found. Running npm install in theme..."
  (cd "${THEME_ROOT}" && npm install --no-audit --no-fund) 2>&1
  if [[ ! -x "$MARP_BIN" ]]; then
    echo "Error: Could not find marp CLI. Run 'cd theme && npm install' first."
    exit 1
  fi
fi

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Error: src/ not found in ${PROJECT_ROOT}"
  echo "Place your decks as Markdown files under src/."
  exit 1
fi

# Directory to serve (default: all of src/)
SERVE_DIR="${1:-$SRC_DIR}"
if [[ "$SERVE_DIR" != /* ]]; then
  SERVE_DIR="${PROJECT_ROOT}/${SERVE_DIR}"
fi
if [[ ! -d "$SERVE_DIR" ]]; then
  echo "Error: directory not found: $SERVE_DIR"
  exit 1
fi

# ─── Asset resolution ─────────────────────────────────────────────────────────
# Markdown refs use ./assets/, resolved relative to each deck. Symlink a merged
# assets dir (theme logos + project assets) next to every deck so the dev server
# resolves images at any depth. All symlinks are removed on exit.

CREATED_LINKS=()

setup_assets() {
  mkdir -p "${PROJECT_ASSETS_DIR}"

  # Symlink theme asset files into the project assets dir (project files win).
  if [[ -d "${THEME_ASSETS_DIR}" ]]; then
    for f in "${THEME_ASSETS_DIR}/"*; do
      [[ -e "$f" ]] || continue
      local name target
      name="$(basename "$f")"
      target="${PROJECT_ASSETS_DIR}/${name}"
      if [[ ! -e "$target" ]]; then
        ln -s "$f" "$target"
        CREATED_LINKS+=("$target")
      fi
    done
  fi

  # Symlink an `assets` dir into every src directory that holds a deck.
  local dir link
  while IFS= read -r dir; do
    [[ "$dir" == "$PROJECT_ASSETS_DIR" ]] && continue
    link="${dir}/assets"
    if [[ ! -e "$link" ]]; then
      ln -s "$PROJECT_ASSETS_DIR" "$link"
      CREATED_LINKS+=("$link")
    fi
  done < <(find "$SRC_DIR" -type f -name '*.md' -exec dirname {} \; | sort -u)
}

cleanup() {
  for link in "${CREATED_LINKS[@]+"${CREATED_LINKS[@]}"}"; do
    rm -f "$link"
  done
}
trap cleanup EXIT

setup_assets

# ─── Dev server ───────────────────────────────────────────────────────────────
echo "Watching ${SERVE_DIR#"$PROJECT_ROOT/"}/ — decks render with the brand in their front matter."
"$MARP_BIN" \
  --theme-set "$THEMES_DIR" \
  --html \
  --allow-local-files \
  --server \
  --watch \
  "$SERVE_DIR"
