#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
BRAND="${BRAND:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(pwd)"

DECK_FILE="${PROJECT_ROOT}/presentation.md"
THEMES_DIR="${THEME_ROOT}/themes"

MARP_BIN="${THEME_ROOT}/node_modules/.bin/marp"
if [[ ! -x "$MARP_BIN" ]]; then
  echo "Marp CLI not found. Running npm install in theme..."
  (cd "${THEME_ROOT}" && npm install --no-audit --no-fund) 2>&1
  if [[ ! -x "$MARP_BIN" ]]; then
    echo "Error: Could not find marp CLI. Run 'cd theme && npm install' first."
    exit 1
  fi
fi

if [[ ! -f "$DECK_FILE" ]]; then
  echo "Error: presentation.md not found in ${PROJECT_ROOT}"
  exit 1
fi

# ─── Asset merging ───────────────────────────────────────────────────────────
# Theme assets (logos) live in theme/assets/.
# Presentation assets (QR codes, images) live in ./assets/.
# All markdown refs use ./assets/, so both sources must be reachable there.

CREATED_SYMLINKS=()

merge_theme_assets_into_project() {
  # Symlink individual theme asset files into the project's assets dir
  # so that both theme logos and presentation images resolve from ./assets/.
  # Project files take precedence — existing files are never overwritten.
  if [[ ! -d "${THEME_ROOT}/assets" ]]; then
    return
  fi

  mkdir -p "${PROJECT_ROOT}/assets"

  for f in "${THEME_ROOT}/assets/"*; do
    [[ -e "$f" ]] || continue
    local name
    name=$(basename "$f")
    local target="${PROJECT_ROOT}/assets/${name}"
    if [[ ! -e "$target" ]]; then
      ln -s "$f" "$target"
      CREATED_SYMLINKS+=("$target")
    fi
  done
}

merge_assets_into_staging() {
  local dest="$1"
  mkdir -p "$dest"

  # Theme assets first (logos)
  if [[ -d "${THEME_ROOT}/assets" ]]; then
    cp -r "${THEME_ROOT}/assets/." "$dest/"
  fi

  # Project assets overlay (presentation-specific images take precedence)
  if [[ -d "${PROJECT_ROOT}/assets" ]]; then
    cp -r "${PROJECT_ROOT}/assets/." "$dest/"
  fi
}

# ─── Brand staging ────────────────────────────────────────────────────────────
INPUT="$DECK_FILE"

if [[ -n "$BRAND" ]]; then
  STAGING_DIR="${PROJECT_ROOT}/.staging/${BRAND}"
  mkdir -p "$STAGING_DIR"

  merge_assets_into_staging "${STAGING_DIR}/assets"

  sed -e "s/^theme: .*/theme: ${BRAND}/" \
      -e "s/craftosphere-logo-light\.svg/${BRAND}-logo-light.svg/g" \
      -e "s/craftosphere-logo\.svg/${BRAND}-logo.svg/g" \
      "$DECK_FILE" > "${STAGING_DIR}/presentation.md"

  INPUT="${STAGING_DIR}/presentation.md"
  echo "Watching ${BRAND} brand (staged copy — restart to pick up edits)"
else
  echo "Watching default brand from presentation.md"

  merge_theme_assets_into_project
fi

# ─── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
  for link in "${CREATED_SYMLINKS[@]+"${CREATED_SYMLINKS[@]}"}"; do
    rm -f "$link"
  done
}
trap cleanup EXIT

# ─── Dev server ───────────────────────────────────────────────────────────────
SERVE_DIR="$(dirname "$INPUT")"

echo "Starting dev server..."
"$MARP_BIN" \
  --theme-set "$THEMES_DIR" \
  --html \
  --allow-local-files \
  --server \
  --watch \
  "$SERVE_DIR"
