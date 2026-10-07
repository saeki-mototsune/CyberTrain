# site/

The CyberTrain homepage (`index.html`), the getting-started tutorial
(`tutorial.html`) and the playground page (`playground.html`, the way into
the GitHub Codespaces playground): static HTML and CSS with no build step, no
framework and no third-party requests. `assets/site.js` only adds copy
buttons, marks the current step in the contents lists and closes the language
menu; every page works with JavaScript off. Each page is also translated
into four languages (see [Translations](#translations)).

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

## Translations

The three pages are also published in Japanese (`ja/`), Simplified Chinese
(`zh/`), Russian (`ru/`) and French (`fr/`), at the same file names:
`ja/tutorial.html` is the Japanese `tutorial.html`. English is the source;
each translation is a copy of the English page with only its text translated:

- same markup, ids, anchors and links, with `../` in front of `assets/` and
  `api/` (the API reference is English only);
- code blocks unchanged, except the `# comments` in shell blocks; inline
  `<code>` unchanged;
- app output and VS Code labels quoted in prose stay in English.

Every page carries `<link rel="alternate" hreflang>` for all five languages,
and a language menu in the header (a `<details>`, so it works without
JavaScript) and a language list in the footer that link to the same page in
each language. `assets/site.js` takes the copy button's words from
`<html lang>`, and `assets/style.css` adds Japanese and Chinese system fonts
after Archivo, which is latin only (Cyrillic falls back to the system sans).

When an English page changes, change the four translations with it, then run

```sh
script/check-site-i18n          # all languages; or: script/check-site-i18n ja
```

which fails when a translation's markup, code blocks or inline code no longer
match the English page, and lists text nodes that still look English.
