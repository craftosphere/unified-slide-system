# CI/CD Setup

The Unified Slide System provides a **reusable GitHub Actions workflow** (`build-presentation.yml`). Presentation repos call it to lint, build all brands in parallel, and upload per-brand zip artifacts. Tagged pushes also create a GitHub Release.

## Workflow inputs

| Input       | Required | Default                              | Description                                         |
| ----------- | -------- | ------------------------------------ | --------------------------------------------------- |
| `theme-ref` | no       | *(submodule commit)*                 | Git ref (tag, branch, SHA) to check out in `theme/` |
| `brands`    | no       | `["brix", "craftosphere", "dojo"]`   | JSON array of brands to build                       |

## Setup

Create `.github/workflows/build.yml` in your presentation repo:

```yaml
name: Build Presentation
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:
  workflow_dispatch:

jobs:
  build:
    uses: craftosphere/unified-slide-system/.github/workflows/build-presentation.yml@main
    permissions:
      contents: write
    with:
      theme-ref: main
```

That's it — one workflow file, no secrets or tokens needed. Pushes to `main` and pull requests trigger lint + build. Pushing a `v*` tag also creates a GitHub Release with per-brand zips attached.

For reproducible CI builds, pin to a tag: `...@v1` with `theme-ref: v1`.

## What the workflow does

1. **Lint** — runs `markdownlint-cli2` and `cspell` on all Markdown files.
2. **Build** — for each brand in the matrix: checks out the theme submodule, installs dependencies, installs Playwright Chromium, stages a per-brand copy of the deck (theme + logo swap), builds HTML and PDF, bundles resources for offline use, and packages the output as a zip.
3. **Release** — on tagged pushes, creates a GitHub Release with all brand zips attached.

## Build artifacts

Each brand produces a zip containing an HTML file, a PDF file, and a `resources/` directory with fonts, images, and assets bundled for offline use. Artifacts are retained for 30 days.
