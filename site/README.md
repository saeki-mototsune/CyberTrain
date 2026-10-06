# site/

The CyberTrain homepage (`index.html`), the getting-started tutorial
(`tutorial.html`) and the playground page (`playground.html`, the way into
the GitHub Codespaces playground): static HTML and CSS with no build step, no
framework and no third-party requests. `assets/site.js` only adds copy
buttons and marks the current step in the contents lists; every page works
with JavaScript off.

- `assets/brand/` — the logo files and [BRAND.md](assets/brand/BRAND.md)
  (construction system, colour tokens, clear space, which file to use where).
- `assets/fonts/` — Archivo and JetBrains Mono, latin subsets, self-hosted
  under the SIL Open Font License (`OFL-*.txt`).
- `assets/og.png` — the social card.

`api/` is not in the repository: it is the API reference, which
`script/api-docs` builds with YARD (see the comment at its top) and the
Pages workflow builds before each deploy. The header and footer link to it.

Preview locally:

```sh
script/api-docs                       # optional: builds site/api/ (needs the yard, kramdown, kramdown-parser-gfm gems)
python3 -m http.server -d site 8000   # http://localhost:8000
```

Publishing: [.github/workflows/pages.yml](../.github/workflows/pages.yml)
deploys this directory to GitHub Pages on every push to `main` that touches
it. One-time setup in the repository settings: Pages → Build and deployment →
Source: **GitHub Actions**. Links between the pages and to their assets are
relative, so the site works from the `/CyberTrain/` project path (the `og:image`
URLs are absolute, as social previews require).

Content rule: every command, code block and claim on these pages comes from
[README.md](../README.md), [examples/blog](../examples/blog) or
[docs/](../docs); when those change, change the site to match.
