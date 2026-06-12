# CI/CD Setup

The Unified Slide System provides a **reusable GitHub Actions workflow** (`build-presentation.yml`). Presentation repos call it to lint, build every deck under `src/`, and upload a single build zip. Tagged pushes also create a GitHub Release.

Each deck under `src/` is one build target and declares its own brand, size, and layout in front matter. The build renders each deck once and mirrors the `src/` tree into `build/`.

## Workflow inputs

| Input       | Required | Default                              | Description                                         |
| ----------- | -------- | ------------------------------------ | --------------------------------------------------- |
| `theme-ref` | no       | *(submodule commit)*                 | Git ref (tag, branch, SHA) to check out in `theme/` |

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

That's it — one workflow file, no secrets or tokens needed. Pushes to `main` and pull requests trigger lint + build. Pushing a `v*` tag also creates a GitHub Release with the build zip attached.

For reproducible CI builds, pin to a tag: `...@v1` with `theme-ref: v1`.

## What the workflow does

1. **Lint** — runs `npm run lint:md` and `npm run lint:spell` if they exist in the presentation repo's `package.json`. Repos without lint scripts skip this stage automatically.
2. **Build** — checks out the theme submodule, installs dependencies, installs Playwright Chromium, then builds every deck under `src/` (each as authored, with its own brand/size/layout), bundles resources for offline use, and packages the mirrored `build/` tree as a single zip.
3. **Release** — on tagged pushes, creates a GitHub Release with the build zip attached.

## Build artifacts

The build produces one zip per repo containing the mirrored `build/` tree — an HTML and PDF per deck, plus a `resources/` directory with fonts, images, and assets bundled for offline use. Artifacts are retained for 30 days.
