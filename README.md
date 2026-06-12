# Unified Slide System

A multi-brand Marp presentation theme with build pipeline, linting, and CI/CD.

## Create a New Presentation

Bootstrap a fully configured presentation repo with a single command — no need to clone the theme first:

```bash
bash <(curl -sL https://raw.githubusercontent.com/craftosphere/unified-slide-system/main/scripts/bootstrap.sh)
```

The script prompts for a presentation title, repo name, default brand, and whether to create a remote GitHub repo (with owner, visibility, and description). It then scaffolds the full project: theme submodule, build scripts, Markdown and spell check linting, commit hooks, CI/CD workflow, a starter deck, and a README with build status badges.

Before committing, the script runs lint checks. If they fail (e.g. unknown words in the title), it skips the commit and push and tells you what to fix.

Prerequisites: `git`, `node` 20+, `npm`. The GitHub CLI (`gh`) is required only if you choose to create a remote repo.

---

# CI/CD Setup

The Unified Slide System provides a **reusable GitHub Actions workflow** (`build-presentation.yml`). Presentation repos call it to lint, build every deck under `src/`, and upload a single build zip. Tagged pushes also create a GitHub Release.

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
```

That's it — one workflow file, no secrets or tokens needed. Pushes to `main` and pull requests trigger lint + build. Pushing a tag also creates a GitHub Release with per-brand zips attached.

## What the workflow does

1. **Lint** — runs `lint:md` and `lint:spell` scripts from the presentation repo's `package.json` if they exist. Repos without lint scripts skip this stage.
2. **Build** — checks out the theme submodule, installs dependencies, installs Playwright Chromium, then builds every deck under `src/` (each as authored, with its own brand/size/layout), bundles resources for offline use, and packages the mirrored `build/` tree as a single zip.
3. **Release** — on tagged pushes, creates a GitHub Release with the build zip attached.

## Authoring decks

Each Markdown file under `src/` is one build target; output mirrors the tree
(`src/<path>/<name>.md` → `build/<path>/<name>.{html,pdf}`). A deck selects its
brand, size, and layout independently in front matter — for example a landscape
talk and a portrait LinkedIn carousel can live in the same repo:

```yaml
---
theme: craftosphere # brand → colors + fonts
size: linkedin-carousel # 1080×1350 portrait (omit for default 16:9)
class: carousel # layout
paginate: true
---
```

### Sharing content across decks (`@include`)

A deck can pull in shared content with an include comment on its own line:

```markdown
<!-- @include: ../_partials/body.md -->
```

The path resolves relative to the including file, and includes may nest. The
build expands them while staging. This lets many thin decks share one body —
e.g. the same slides rendered under every brand, where only the front matter
(`theme:`) differs:

```text
src/
  _partials/
    body.md          ← the shared slides (authored once)
  brix.md            ← front matter + <!-- @include: _partials/body.md -->
  craftosphere.md    ← front matter + <!-- @include: _partials/body.md -->
```

Files and directories whose name starts with `_` are **partials**: they are
never built on their own, only pulled in via `@include`.

> **Limitation:** includes are expanded at build time only. `npm run watch`
> serves the raw deck files, so a thin wrapper deck previews without its
> included body — run `npm run build` to see the composed result.

## Build artifacts

The build produces one zip per repo containing the mirrored `build/` tree — an HTML and PDF per deck, plus a `resources/` directory with fonts, images, and assets bundled for offline use. Artifacts are retained for 30 days.
