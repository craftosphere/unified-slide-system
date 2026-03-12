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
2. **Build** — for each brand in the matrix: checks out the theme submodule, installs dependencies, installs Playwright Chromium, stages a per-brand copy of the deck (theme + logo swap), builds HTML and PDF, bundles resources for offline use, and packages the output as a zip.
3. **Release** — on tagged pushes, creates a GitHub Release with all brand zips attached.

## Build artifacts

Each brand produces a zip containing an HTML file, a PDF file, and a `resources/` directory with fonts, images, and assets bundled for offline use. Artifacts are retained for 30 days.
