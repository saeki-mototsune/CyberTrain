# site/

The CyberTrain homepage (`index.html`) and the getting-started tutorial
(`tutorial.html`): static HTML and CSS with no build step, no framework and
no third-party requests. `assets/site.js` only adds copy buttons and the
active tutorial step; every page works with JavaScript off.

- `assets/brand/` — the logo files and [BRAND.md](assets/brand/BRAND.md)
  (construction system, colour tokens, clear space, which file to use where).
- `assets/fonts/` — Archivo and JetBrains Mono, latin subsets, self-hosted
  under the SIL Open Font License (`OFL-*.txt`).
- `assets/og.png` — the social card.

Preview locally:

```sh
python3 -m http.server -d site 8000   # http://localhost:8000
```

Publishing: [.github/workflows/pages.yml](../.github/workflows/pages.yml)
deploys this directory to GitHub Pages on every push to `main` that touches
it. One-time setup in the repository settings: Pages → Build and deployment →
Source: **GitHub Actions**. All links are relative, so the site works from the
`/CyberTrain/` project path.

Content rule: every command, code block and claim on these pages comes from
[README.md](../README.md), [examples/blog](../examples/blog) or
[docs/](../docs); when those change, change the site to match.
