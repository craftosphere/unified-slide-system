#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
ALL_BRANDS=(brix craftosphere dojo)

if [[ -n "${BRAND:-}" ]]; then
  BRANDS=("$BRAND")
else
  BRANDS=( "${ALL_BRANDS[@]}" )
fi
if [[ "${SKIP_PDF:-}" == "1" ]]; then
  FORMATS=(html)
else
  FORMATS=(html pdf)
fi

# Resolve paths — script can be called from presentation repo or theme repo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The working directory (where the user calls from) is the presentation root
PROJECT_ROOT="$(pwd)"

# Deck file is always in the project root
DECK_FILE="${PROJECT_ROOT}/presentation.md"
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
# All markdown refs use ./assets/, so both sources must be merged into staging.

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

# ─── Build functions ─────────────────────────────────────────────────────────

build_brand() {
  local brand="$1"
  local format="$2"
  local outdir="${BUILD_DIR}/${brand}"

  mkdir -p "$outdir" "${STAGING_DIR}/${brand}"

  # Merge theme + project assets so all relative paths resolve
  merge_assets_into_staging "${STAGING_DIR}/${brand}/assets"

  # Create per-brand copy with theme and logo swapped
  local staged="${STAGING_DIR}/${brand}/presentation.md"
  sed -e "s/^theme: .*/theme: ${brand}/" \
      -e "s/craftosphere-logo-light\.svg/${brand}-logo-light.svg/g" \
      -e "s/craftosphere-logo\.svg/${brand}-logo.svg/g" \
      "$DECK_FILE" > "$staged"

  # Derive output filename from project directory name
  local repo_name
  repo_name=$(basename "${PROJECT_ROOT}")
  local out_name="${repo_name}"

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
    -o "${outdir}/${out_name}.${format}" \
    "$staged"; then
    echo "  ⚠  ${brand}/${format} failed (may need a browser for PDF export)"
  fi
}

build_all() {
  if [[ ! -f "$DECK_FILE" ]]; then
    echo "Error: presentation.md not found in ${PROJECT_ROOT}"
    echo "Place your presentation.md in the project root."
    exit 1
  fi

  echo "Cleaning build/..."
  for brand in "${BRANDS[@]}"; do
    rm -rf "${BUILD_DIR:?}/${brand}"
  done
  rm -rf "${STAGING_DIR}"

  setup_browser

  for brand in "${BRANDS[@]}"; do
    for format in "${FORMATS[@]}"; do
      echo "Building ${brand}/${format}..."
      build_brand "$brand" "$format"
    done
  done

  rm -rf "${STAGING_DIR}"

  # Post-build: bundle resources for offline use (HTML only)
  echo ""
  echo "Bundling resources for offline use..."
  python3 "${SCRIPT_DIR}/bundle-resources.py" "${BUILD_DIR}" "${THEME_ASSETS_DIR}" "${PROJECT_ASSETS_DIR}"

  echo ""
  echo "Done. Output in ${BUILD_DIR}/"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
build_all
