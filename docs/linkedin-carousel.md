# LinkedIn carousel layout

A brand-agnostic portrait layout for LinkedIn document carousels. The **layout**
and the **brand theme** are selected independently — any brand can render a
carousel, and the carousel never hard-codes brand colors or fonts.

See `examples/linkedin-carousel.md` for a complete 8-slide deck.

## Selecting it

Set three directives in the deck front matter:

```yaml
---
theme: craftosphere # brand → colors + fonts (any brand works)
size: linkedin-carousel # registered 1080×1350 portrait size
class: carousel # this layout → geometry + chrome
paginate: true # drives the `n / total` counter
---
```

`size` is a Marp Core directive backed by a named size registered in
`themes/base/base.css`. Because it is array-type theme metadata, the
registration in `base` propagates to every brand through `@import 'base'`.
Two sizes are registered:

| Name                | Dimensions  | Use                       |
| ------------------- | ----------- | ------------------------- |
| `presentation`      | 1280 × 720  | default 16:9 landscape    |
| `linkedin-carousel` | 1080 × 1350 | 4:5 portrait carousel     |

## Authoring a slide

Separate slides with `---`. One idea per slide.

### Cover slide

Centered title and subtitle. Apply the `cover` modifier on that slide only:

```markdown
<!-- _class: carousel cover -->

# I Wanted a Critic, Not a Faster Typist

The principles that turned my AI from an intern into a colleague.
```

### Content slide

A heading plus a short body. Highlight the single most important phrase with a
`<mark>` pill — one per slide. It works inside the heading or the body:

```markdown
## Ask, Do Not Assume

When the request is unclear, <mark>stop and ask</mark>. A thirty-second question
beats a ten-minute redo in the wrong direction.
```

Markdownlint forbids more than one `# ` heading per file, so use `## ` for every
slide after the cover. The carousel styles `h1` and `h2` identically.

### Optional corner doodle

Drop one line-art icon in the top corner. Bring your own SVG from any icon
library (Lucide, Tabler, Heroicons, …) or hand-draw one — no icon set ships with
the theme. Use `currentColor` so the icon picks up the brand accent:

```html
<div class="doodle">
  <svg viewBox="0 0 24 24" stroke-width="2" fill="none">
    <circle cx="12" cy="12" r="8" stroke="currentColor" />
  </svg>
</div>
```

A raster icon works too:

```html
<div class="doodle"><img src="./assets/icon.png" alt="" /></div>
```

### Closing call-to-action

A centered italic prompt line for the final slide:

```html
<p class="ask">What would you put on slide one?</p>
```

## Colors and contrast

The carousel inherits the active brand's palette and fonts. Notes:

- **Background.** Craftosphere defaults to a light canvas. For the dark canvas
  typical of editorial carousels, add `dark` to the class list:
  `class: carousel dark`. BriX and Dojo are dark by default.
- **Highlight pill.** Uses `--color-accent` on `--text-on-accent`. Confirm that
  pairing meets WCAG AA contrast (4.5:1) for each brand you ship.
- **Wordmark.** If you set a footer logo, it sits bottom-right (the page counter
  owns bottom-left). Logo light/dark switching follows the brand rules.

## Building

The carousel is deck-level configuration, so the standard build needs no
changes. The PDF is the artifact you upload to LinkedIn. Render directly with
the Marp CLI:

```bash
node_modules/.bin/marp --theme-set themes --html --allow-local-files \
  --pdf examples/linkedin-carousel.md -o carousel.pdf
```
