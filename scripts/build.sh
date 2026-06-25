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

# ─── Options ─────────────────────────────────────────────────────────────────
# Builds are incremental by default: each artifact is rebuilt only when the
# expanded source hash is missing or changed (see the build manifest below).
# Pass --clean to wipe the build/ and .staging/ trees first and rebuild all.
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    -h|--help)
      echo "Usage: build.sh [--clean]"
      echo "  --clean   Delete build/ and .staging/ before building (full rebuild)."
      echo "  (default) Incremental — rebuild only decks whose source hash changed."
      echo "  SKIP_PDF=1 env var builds HTML only."
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

# Resolve paths — script can be called from a presentation repo or the theme repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The working directory (where the user calls from) is the presentation root
PROJECT_ROOT="$(pwd)"

# Decks live under src/; output mirrors the tree
SRC_DIR="${PROJECT_ROOT}/src"
BUILD_DIR="${PROJECT_ROOT}/build"
STAGING_DIR="${PROJECT_ROOT}/.staging"

# Incremental-build manifest: maps each artifact key (rel|format) to the
# sha256 of the deck's *expanded* source (after @include expansion, so editing
# a shared partial busts the cache). Lives in build/ as a local cache.
MANIFEST_FILE="${BUILD_DIR}/.build-manifest"

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

# ─── Incremental-build manifest ──────────────────────────────────────────────
# Portable across bash 3.2 (macOS) — no associative arrays. The manifest is a
# tab-delimited file (`<sha256>\t<key>`); lookups and updates go through awk so
# deck paths may contain spaces (but never tabs).

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

manifest_get() {   # key → prints the stored hash, or nothing
  local key="$1"
  [[ -f "$MANIFEST_FILE" ]] || return 0
  awk -F'\t' -v k="$key" '$2 == k { print $1; exit }' "$MANIFEST_FILE"
}

manifest_set() {   # key hash → upsert the entry
  local key="$1" hash="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$MANIFEST_FILE" ]]; then
    awk -F'\t' -v k="$key" '$2 != k' "$MANIFEST_FILE" > "$tmp"
  fi
  printf '%s\t%s\n' "$hash" "$key" >> "$tmp"
  mv "$tmp" "$MANIFEST_FILE"
}

# ─── Build functions ─────────────────────────────────────────────────────────

render_deck() {
  local staged="$1" out_dir="$2" name="$3" format="$4" rel="$5"

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
    "$staged"; then
    echo "  ⚠  ${rel%.md}.${format} failed (may need a browser for PDF export)"
    return 1
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

  if [[ "$CLEAN" == "1" ]]; then
    echo "Cleaning build/ and .staging/ (--clean)..."
    rm -rf "${BUILD_DIR}" "${STAGING_DIR}"
  fi
  # Staging is always transient — start from a clean slate.
  rm -rf "${STAGING_DIR}"
  mkdir -p "${BUILD_DIR}"

  setup_browser

  local built_any=0
  for deck in "${decks[@]}"; do
    local rel="${deck#"${SRC_DIR}/"}"
    local reldir name stage_dir out_dir staged src_hash assets_merged
    reldir="$(dirname "$rel")"
    name="$(basename "${rel%.md}")"
    stage_dir="${STAGING_DIR}/${reldir}"
    out_dir="${BUILD_DIR}/${reldir}"
    mkdir -p "$stage_dir" "$out_dir"

    # Expand @include directives first — the hash is over the expanded source,
    # so a change in a shared partial rebuilds every deck that includes it.
    staged="${stage_dir}/${name}.md"
    expand_includes "$deck" "$staged"
    src_hash="$(hash_file "$staged")"
    assets_merged=0

    for format in "${FORMATS[@]}"; do
      local key="${rel}|${format}"
      local out_file="${out_dir}/${name}.${format}"

      if [[ "$(manifest_get "$key")" == "$src_hash" && -f "$out_file" ]]; then
        echo "Up to date: ${rel%.md}.${format}"
        continue
      fi

      # Merge assets next to the staged deck (once per deck) so ./assets/ resolves
      if [[ "$assets_merged" == "0" ]]; then
        merge_assets_into_staging "${stage_dir}/assets"
        assets_merged=1
      fi

      echo "Building ${rel%.md}.${format}..."
      if render_deck "$staged" "$out_dir" "$name" "$format" "$rel"; then
        manifest_set "$key" "$src_hash"
        built_any=1
      fi
      # On failure the hash is not recorded, so the next run retries the artifact.
    done
  done

  rm -rf "${STAGING_DIR}"

  if [[ "$built_any" == "0" ]]; then
    echo ""
    echo "Everything up to date. Nothing to build (use --clean to force a rebuild)."
    return 0
  fi

  # Post-build: bundle resources for offline use (HTML only). Idempotent — once
  # an HTML is bundled it has no remaining ./assets/ or remote refs to rewrite,
  # so re-running over the whole tree leaves already-bundled decks untouched.
  echo ""
  echo "Bundling resources for offline use..."
  python3 "${SCRIPT_DIR}/bundle-resources.py" "${BUILD_DIR}" "${THEME_ASSETS_DIR}" "${PROJECT_ASSETS_DIR}"

  echo ""
  echo "Done. Output in ${BUILD_DIR}/ (mirrors src/)."
}

# ─── Main ─────────────────────────────────────────────────────────────────────
build_all
