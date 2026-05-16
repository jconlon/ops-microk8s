# docs/ — Claude Code Instructions

This directory contains all cluster documentation as HTML pages. Follow these rules when creating or editing docs.

## Adding a new page — 3-step checklist

1. **Create `docs/<name>.html`** — copy the template structure below. All pages must use the shared CSS variables; do not invent new colour values.
2. **Add a card to `docs/index.html`** — in the Documentation section, add a `.doc-card` `<a>` block with icon, title, description, and `<span class="doc-card-tag tag-html">HTML</span>`.
3. **Add a `just` recipe to `justfile`** — under the `# ── Docs ──` section, add a recipe named `<name>-docs` that runs `xdg-open docs/<name>.html`.

Never leave a new page without both the index card and the just recipe.

## HTML template

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Page Title — ops-microk8s</title>
<style>
  /* Copy the full :root + element styles from any existing page (cluster.html is the canonical reference).
     Do not strip or abbreviate — all pages share the same variable set. */
</style>
</head>
<body>
<div class="page">

<p class="breadcrumb"><a href="index.html">ops-microk8s</a> › Page Title</p>
<h1>Page Title</h1>
<p class="subtitle">One-line description</p>

<!-- sections -->

<hr>
<p style="font-size:0.82rem; color:var(--muted);">
  <a href="index.html">← ops-microk8s docs</a>
</p>

</div>
</body>
</html>
```

## CSS variables (never hardcode colours)

| Variable | Use |
|---|---|
| `--bg` | Page background |
| `--surface` / `--surface2` | Cards, table headers |
| `--border` | All borders |
| `--text` | Body text |
| `--muted` | Secondary text, subtitles |
| `--accent` | Headings, links, highlights |
| `--accent2` | Purple accent |
| `--green` / `--yellow` / `--orange` / `--red` | Status colours |
| `--code-bg` | `<pre>` and `<code>` backgrounds |

## Common patterns

### Callouts
```html
<div class="callout">                        <!-- blue, default -->
<div class="callout callout-tip">            <!-- green -->
<div class="callout callout-warn">           <!-- yellow -->
```
Always include a `<strong>` label as the first child.

### Badges
```html
<span class="badge badge-green">OK</span>
<span class="badge badge-blue">Info</span>
<span class="badge badge-yellow">Warning</span>
```

### Tables — always use `<thead>` with `<th>` and `<tbody>` with `<td>`. Never use bare `<table>` without headers.

### Code — inline: `<code>value</code>`. Block: `<pre>...</pre>`. Never use markdown fences inside HTML.

## Rules

- **No `.md` files** — convert to HTML. Markdown is not rendered in the browser and breaks the visual consistency.
- **No inline styles for colours** — use CSS variables.
- **No external CDN dependencies** — the docs work offline.
- **Always include the breadcrumb** — `ops-microk8s › Page Title` linking back to `index.html`.
- **Always include the footer `<hr>` + back link** at the bottom of every page.
- **`mc` commands use no prefix** — Claude Code sessions run inside the devbox shell; never write `devbox run -- mc`.
