#!/usr/bin/env bash
set -euo pipefail

# ─── Build every deck under src/ ──────────────────────────────────────────────
# Each Markdown file in src/ is one build target. The deck declares its own
# brand, size, and layout in front matter (theme:, size:, class:); the build
# renders it once, as authored — no per-brand fan-out. Output mirrors the src/
# tree: src/<path>/<name>.md → build/<path>/<name>.{html,pdf}.

if [[ "${SKIP_PDF:-}" == "1" ]]; then
  FORMATS=(html)
else
  FORMATS=(html pdf)
fi

# Resolve paths — script can be called from a presentation repo or the theme repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The working directory (where the user calls from) is the presentation root
PROJECT_ROOT="$(pwd)"

# Decks live under src/; output mirrors the tree
SRC_DIR="${PROJECT_ROOT}/src"
BUILD_DIR="${PROJECT_ROOT}/build"
STAGING_DIR="${PROJECT_ROOT}/.staging"

# Theme assets and themes come from the theme repo
THEMES_DIR="${THEME_ROOT}/themes"
THEME_ASSETS_DIR="${THEME_ROOT}/assets"

# Project-level assets (QR codes, images specific to this presentation)
PROJECT_ASSETS_DIR="${PROJECT_ROOT}/assets"

# Use marp CLI from the theme's node_modules
MARP_BIN="${THEME_ROOT}/node_modules/.bin/marp"
if [[ ! -x "$MARP_BIN" ]]; then
  echo "Marp CLI not found. Running npm install in theme..."
  (cd "${THEME_ROOT}" && npm install --no-audit --no-fund) 2>&1
  if [[ ! -x "$MARP_BIN" ]]; then
    echo "Error: Could not find marp CLI. Run 'cd theme && npm install' first."
    exit 1
  fi
fi

# ─── Browser setup for PDF export ────────────────────────────────────────────
find_playwright_browser() {
  local search_dirs=()

  if [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
    search_dirs+=("$PLAYWRIGHT_BROWSERS_PATH")
  fi

  case "$(uname -s)" in
    Darwin)
      search_dirs+=("${HOME}/Library/Caches/ms-playwright")
      ;;
    *)
      search_dirs+=("${XDG_CACHE_HOME:-${HOME}/.cache}/ms-playwright")
      ;;
  esac

  search_dirs+=("${HOME}/.cache/ms-playwright")

  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue

    local hs
    hs=$(find "$dir" -name "headless_shell" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$hs" && -x "$hs" ]]; then
      echo "$hs"
      return 0
    fi

    local chrome
    chrome=$(find "$dir" -path "*/chrome-linux/chrome" -type f 2>/dev/null | head -1 || true)
    if [[ -n "$chrome" && -x "$chrome" ]]; then
      echo "$chrome"
      return 0
    fi
  done

  return 1
}

setup_browser() {
  if [[ "${FORMATS[*]}" == "html" ]]; then
    return 0
  fi

  if [[ -n "${CHROME_PATH:-}" ]] && [[ -x "$CHROME_PATH" ]]; then
    echo "Using browser: $CHROME_PATH"
    return 0
  fi

  local system_chrome
  system_chrome=$(command -v google-chrome-stable || command -v google-chrome || command -v chromium-browser || command -v chromium || true)
  if [[ -n "$system_chrome" ]]; then
    echo "Using system browser: $system_chrome"
    export CHROME_PATH="$system_chrome"
    return 0
  fi

  if [[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]]; then
    echo "Using macOS Chrome"
    export CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    return 0
  fi

  local pw_browser
  pw_browser=$(find_playwright_browser) || pw_browser=""

  if [[ -z "$pw_browser" ]]; then
    echo "No browser found. Installing Playwright Chromium..."
    (cd "${THEME_ROOT}" && npx playwright install chromium) 2>&1
    pw_browser=$(find_playwright_browser) || pw_browser=""
  fi

  if [[ -z "$pw_browser" ]]; then
    echo "  ⚠  Could not find or install a browser. PDF export will be skipped."
    FORMATS=(html)
    return 0
  fi

  echo "Using Playwright browser: $pw_browser"

  local wrapper="${SCRIPT_DIR}/chrome-sandbox-wrapper.sh"
  cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
exec "$pw_browser" \\
  --no-sandbox \\
  --single-process \\
  --disable-dev-shm-usage \\
  --disable-gpu \\
  "\$@"
WRAPPER
  chmod +x "$wrapper"

  export CHROME_PATH="$wrapper"
  export CHROME_NO_SANDBOX=1
}

# ─── Asset merging ───────────────────────────────────────────────────────────
# Theme assets (logos) live in theme/assets/.
# Presentation assets (QR codes, images) live in ./assets/.
# All markdown refs use ./assets/, so both sources are merged next to each
# staged deck so the relative paths resolve regardless of the deck's depth.

merge_assets_into_staging() {
  local dest="$1"
  mkdir -p "$dest"

  # Theme assets first (logos)
  if [[ -d "${THEME_ASSETS_DIR}" ]]; then
    cp -r "${THEME_ASSETS_DIR}/." "$dest/"
  fi

  # Project assets overlay (presentation-specific images take precedence)
  if [[ -d "${PROJECT_ASSETS_DIR}" ]]; then
    cp -r "${PROJECT_ASSETS_DIR}/." "$dest/"
  fi
}

# ─── Include expansion ───────────────────────────────────────────────────────
# Decks may pull in shared content with an include comment on its own line:
#   <!-- @include: ../_partials/body.md -->
# The path is resolved relative to the including file. Files and directories
# whose name starts with `_` are partials — they are never built on their own.
# This lets many thin per-theme decks share one body (front matter differs only).

expand_includes() {
  local src="$1" out="$2"
  python3 - "$src" "$out" <<'PY'
import os, re, sys
src, out = sys.argv[1], sys.argv[2]
INCLUDE = re.compile(r'^[ \t]*<!--\s*@include:\s*(.+?)\s*-->[ \t]*$')

def expand(path, stack):
    rp = os.path.realpath(path)
    if rp in stack:
        sys.exit(f"Circular @include detected at {path}")
    if not os.path.isfile(path):
        sys.exit(f"@include target not found: {path}")
    base = os.path.dirname(path)
    chunks = []
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            m = INCLUDE.match(line.rstrip('\n'))
            if m:
                target = os.path.normpath(os.path.join(base, m.group(1)))
                chunks.append(expand(target, stack | {rp}))
            else:
                chunks.append(line if line.endswith('\n') else line + '\n')
    return ''.join(chunks)

with open(out, 'w', encoding='utf-8') as fh:
    fh.write(expand(src, frozenset()))
PY
}

# ─── Build functions ─────────────────────────────────────────────────────────

build_deck() {
  local deck="$1"        # absolute path to a src/*.md file
  local format="$2"

  local rel="${deck#"${SRC_DIR}/"}"   # path relative to src/, e.g. linkedin/critic.md
  local reldir name
  reldir="$(dirname "$rel")"          # linkedin   (or "." for a root-level deck)
  name="$(basename "${rel%.md}")"     # critic

  local stage_dir="${STAGING_DIR}/${reldir}"
  local out_dir="${BUILD_DIR}/${reldir}"
  mkdir -p "$stage_dir" "$out_dir"

  # Merge assets next to the staged deck so ./assets/ resolves
  merge_assets_into_staging "${stage_dir}/assets"

  # Stage the deck, expanding any @include directives (the deck owns its
  # front matter; no theme/logo rewriting).
  expand_includes "$deck" "${stage_dir}/${name}.md"

  local extra_flags=()
  if [[ "$format" != "html" ]]; then
    extra_flags+=(--browser chrome --browser-protocol cdp --browser-timeout 60)
  fi

  if ! "$MARP_BIN" \
    --theme-set "${THEMES_DIR}" \
    --"${format}" \
    --html \
    --allow-local-files \
    "${extra_flags[@]}" \
    -o "${out_dir}/${name}.${format}" \
    "${stage_dir}/${name}.md"; then
    echo "  ⚠  ${rel%.md}.${format} failed (may need a browser for PDF export)"
  fi
}

build_all() {
  if [[ ! -d "$SRC_DIR" ]]; then
    echo "Error: src/ not found in ${PROJECT_ROOT}"
    echo "Place your decks as Markdown files under src/. Output mirrors the src/ tree."
    exit 1
  fi

  # Collect decks recursively
  local decks=()
  while IFS= read -r -d '' f; do
    decks+=("$f")
  done < <(find "$SRC_DIR" -type f -name '*.md' -not -path '*/_*' -print0)

  if [[ ${#decks[@]} -eq 0 ]]; then
    echo "Error: no .md decks found under ${SRC_DIR}"
    exit 1
  fi

  echo "Cleaning build/..."
  rm -rf "${BUILD_DIR}" "${STAGING_DIR}"

  setup_browser

  for deck in "${decks[@]}"; do
    local rel="${deck#"${SRC_DIR}/"}"
    for format in "${FORMATS[@]}"; do
      echo "Building ${rel%.md}.${format}..."
      build_deck "$deck" "$format"
    done
  done

  rm -rf "${STAGING_DIR}"

  # Post-build: bundle resources for offline use (HTML only)
  echo ""
  echo "Bundling resources for offline use..."
  python3 "${SCRIPT_DIR}/bundle-resources.py" "${BUILD_DIR}" "${THEME_ASSETS_DIR}" "${PROJECT_ASSETS_DIR}"

  echo ""
  echo "Done. Output in ${BUILD_DIR}/ (mirrors src/)."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
build_all
