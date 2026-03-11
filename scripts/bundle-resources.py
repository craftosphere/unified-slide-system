#!/usr/bin/env python3
"""
Post-build script to make Marp HTML presentations self-contained.

For each HTML file in the dist directory:
1. Downloads Google Fonts (woff2) and inlines @font-face rules
2. Downloads remote images (Unsplash, etc.) to a local resources folder
3. Rewrites all URLs in the HTML to point to local files
4. Copies local assets (logos, QR codes) to the resources folder

The result is an HTML file + resources/ folder that works offline.
"""

import os
import re
import sys
import hashlib
import urllib.request
from pathlib import Path


# User-Agent that makes Google Fonts return woff2 format
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0"


def download(url, dest, ua=None):
    """Download a URL to a local file. Returns True on success."""
    if dest.exists():
        return True
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": ua or UA})
        with urllib.request.urlopen(req, timeout=30) as resp:
            dest.write_bytes(resp.read())
        return True
    except Exception as e:
        print(f"  ⚠  Failed to download {url}: {e}")
        return False


def url_hash(url):
    """Short hash of a URL for unique filenames."""
    return hashlib.md5(url.encode()).hexdigest()[:10]


def process_google_fonts(html_content, res_dir):
    """
    Find Google Fonts @import URLs in the HTML, download the CSS and font
    files, then replace the @import with local @font-face rules.
    """
    fonts_dir = res_dir / "fonts"

    # Match @import url('https://fonts.googleapis.com/...')
    import_pattern = re.compile(
        r"""@import\s+url\(\s*['"]?(https://fonts\.googleapis\.com/css2\?[^'")\s]+)['"]?\s*\)\s*;?""",
        re.IGNORECASE,
    )

    imports = import_pattern.findall(html_content)
    if not imports:
        return html_content

    for font_url in imports:
        # Download the Google Fonts CSS
        css_file = fonts_dir / f"gf-{url_hash(font_url)}.css"
        try:
            req = urllib.request.Request(font_url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=15) as resp:
                font_css = resp.read().decode("utf-8")
        except Exception as e:
            print(f"  ⚠  Failed to download font CSS: {e}")
            continue

        # Find all font file URLs in the CSS
        font_file_pattern = re.compile(r"url\((https://fonts\.gstatic\.com/[^)]+)\)")
        font_files = font_file_pattern.findall(font_css)

        for ff_url in font_files:
            # Determine extension
            ext = ".woff2"
            if ".woff?" in ff_url or ff_url.endswith(".woff"):
                ext = ".woff"
            elif ".ttf" in ff_url:
                ext = ".ttf"

            local_name = f"font-{url_hash(ff_url)}{ext}"
            local_path = fonts_dir / local_name

            if download(ff_url, local_path, ua=UA):
                # Rewrite URL in the font CSS
                font_css = font_css.replace(ff_url, f"resources/fonts/{local_name}")

        # Replace the @import with the inlined @font-face CSS
        # Escape the URL for regex
        escaped_url = re.escape(font_url)
        import_re = re.compile(
            rf"""@import\s+url\(\s*['"]?{escaped_url}['"]?\s*\)\s*;?""",
            re.IGNORECASE,
        )
        html_content = import_re.sub(font_css, html_content, count=1)

    return html_content


def process_remote_images(html_content, res_dir):
    """
    Find remote image URLs in the HTML, download them locally,
    and rewrite the HTML to use local paths.
    """
    images_dir = res_dir / "images"

    # Match src="https://..." for images
    img_pattern = re.compile(
        r"""((?:src|href)\s*=\s*['"])(https?://images\.unsplash\.com/[^'"]+)(['"])""",
        re.IGNORECASE,
    )

    matches = img_pattern.findall(html_content)
    if not matches:
        return html_content

    seen = set()
    for prefix, img_url, suffix in matches:
        if img_url in seen:
            continue
        seen.add(img_url)

        # Determine file extension from URL or default to .jpg
        ext = ".jpg"
        local_name = f"img-{url_hash(img_url)}{ext}"
        local_path = images_dir / local_name

        if download(img_url, local_path):
            html_content = html_content.replace(img_url, f"resources/images/{local_name}")

    return html_content


def find_asset(filename, asset_dirs):
    """Search multiple asset directories for a file, return the first match."""
    for d in asset_dirs:
        candidate = d / filename
        if candidate.exists():
            return candidate
    return None


def process_asset_paths(html_content, asset_dirs, res_dir):
    """
    Find local asset references (./assets/...) and copy them to resources/,
    then rewrite paths in the HTML. Searches multiple asset source directories.
    """
    asset_pattern = re.compile(
        r"""(['"])\./assets/([^'"]+)(['"])""",
        re.IGNORECASE,
    )

    matches = asset_pattern.findall(html_content)
    if not matches:
        return html_content

    assets_out = res_dir / "assets"
    assets_out.mkdir(parents=True, exist_ok=True)

    seen = set()
    for q1, filename, q2 in matches:
        if filename in seen:
            continue
        seen.add(filename)

        src_file = find_asset(filename, asset_dirs)

        if src_file is not None:
            dst_file = assets_out / filename
            dst_file.write_bytes(src_file.read_bytes())
            html_content = html_content.replace(
                f"./assets/{filename}", f"resources/assets/{filename}"
            )
        else:
            dirs_str = ", ".join(str(d) for d in asset_dirs)
            print(f"  ⚠  Asset not found: {filename} (searched: {dirs_str})")

    return html_content


def process_html_file(html_path, asset_dirs):
    """Process a single HTML file to make it self-contained."""
    print(f"  Bundling: {html_path.name}")

    res_dir = html_path.parent / "resources"
    res_dir.mkdir(exist_ok=True)

    html_content = html_path.read_text(encoding="utf-8")

    # Step 1: Download and inline Google Fonts
    html_content = process_google_fonts(html_content, res_dir)

    # Step 2: Download remote images
    html_content = process_remote_images(html_content, res_dir)

    # Step 3: Copy and rewrite local assets (logos, QR codes, etc.)
    html_content = process_asset_paths(html_content, asset_dirs, res_dir)

    html_path.write_text(html_content, encoding="utf-8")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <dist-dir> <assets-dir> [<assets-dir> ...]")
        sys.exit(1)

    dist_dir = Path(sys.argv[1])
    asset_dirs = [Path(d) for d in sys.argv[2:] if Path(d).exists()]

    if not dist_dir.exists():
        print(f"Dist directory not found: {dist_dir}")
        sys.exit(1)

    if not asset_dirs:
        print("No valid asset directories found.")
        sys.exit(1)

    # Process all HTML files in dist
    html_files = list(dist_dir.rglob("*.html"))
    if not html_files:
        print("No HTML files found in dist/")
        return

    print(f"Processing {len(html_files)} HTML file(s)...")
    for html_file in html_files:
        process_html_file(html_file, asset_dirs)

    print("Done. All builds are now self-contained.")


if __name__ == "__main__":
    main()
