# docs/guide/

The tutorial and the guides, in Markdown. This directory is their only
source: at deploy, [script/guide-pages](../../script/guide-pages) renders every
file here into the site's page shell (the header, contents list and footer of
the hand-written pages under [site/](../../site)), and the HTML is never
committed. Edit the Markdown, never the generated pages. This file is not a
page; the build skips it.

| Source | Page |
|---|---|
| `tutorial.md` | `tutorial.html` (its front matter sets `path: tutorial.html`) |
| `index.md` | `guide/index.html`, the Guides index the header links to |
| `<name>.md` | `guide/<name>.html` |
| `<lang>/<name>.md` | the same path under `<lang>/`: `ja/tutorial.html`, `ja/guide/install.html` |

The published URLs are under `https://saeki-mototsune.github.io/CyberTrain/`.
The build also writes the old API-reference URLs of the guides as redirects:
`api/file.<name>.html` to the guide, `api/file.walkthrough.html` to the
tutorial.

```text
docs/guide/
  README.md              this file (not built)
  index.md tutorial.md   the Guides index and the tutorial
  install.md models.md … one file per guide
  ja/ zh/ ru/ fr/        the translations, one file per English file, same names
```

English is the source. `ja/`, `zh/`, `ru/` and `fr/` hold the Japanese,
Simplified Chinese, Russian and French translations; each has exactly the
files the English has. See [Translations](#translations).

## Front matter

A file may start with YAML front matter between two `---` lines. Every key is
optional; an unknown key fails the build. Text values are plain text, not
Markdown, except `meta`'s `text`.

| Key | Meaning | Default | In a translation |
|---|---|---|---|
| `path` | The page's path from the language root: `tutorial.html` or `guide/<name>.html`, nothing else | `guide/<name>.html` | equal to the English |
| `title` | `<title>` (before " · CyberTrain") | the `# ` title, as text | translated |
| `description` | `<meta name="description">` | the paragraph after the title, as text | translated |
| `og_title` | `og:title` and the social card's alt text | `title` | translated |
| `og_description` | `og:description` | `description` | translated |
| `og_image` | The social card, a file name in `site/assets/og/<lang>/` | `index.png` | equal to the English |
| `crumb` | The last entry of the breadcrumb | the `# ` title | translated |
| `meta` | Rows under the title: a list of `{term, text}`, `text` inline Markdown (links rewritten as in the body) | none | translated |
| `toc_title` | The contents list's heading | "Contents" in the page's language | translated |
| `nav` | The header entry marked current: `tutorial` or `guides` | `guides` | equal to the English |
| `source_sha256` | The SHA-256 of the English file the translation matches | (none) | required; written by `script/check-guide-i18n --update-sha` |

A translation has the same keys as its English file, plus `source_sha256`.

## Conventions

A source is GitHub Markdown (GFM), so it reads correctly on GitHub too. The
page starts with one `# Title`, then a paragraph, the page's introduction.
Each `## Heading` is a section of the page and an entry in its contents list;
`### Heading` is a subheading. A heading's id is the GitHub slug of the
English heading, in every language, so `install.md#requirements` works from
any translation. Text is kept as written: no smart quotes, and entities
(`&nbsp;`, `&rsquo;`, `&mdash;`) stay entities.

The page's components are written as below;
[render.rb](../../script/guide-pages.d/lib/render.rb) lists them in its header
comment, and [tutorial.md](tutorial.md) uses most of them.

| Write | For |
|---|---|
| `<!-- step NUM #id stage: Text -->` on the line before a `## Heading` | A numbered step: `NUM` (`00`, or `+` / `→` for one shown apart in the contents list), the section's id, and an optional stage line (inline Markdown). A `##` without one is numbered 01, 02, … |
| `> [!WHY]` then one paragraph | The "Why" line under a heading |
| `> [!RULE] Aria text`, `> [!COMPILE] Aria text`, `> [!EXAMPLE] Aria text`, then `> ### Title` and the body | A callout (Spinel rule, what compiles, worked example). The text after the marker is the callout's accessible name; without it, the kind and the title |
| `> [!NOTE]` then one paragraph | A note |
| `<details><summary>Title — summary</summary>`, a blank line, the body (Markdown), a blank line, `</details>` | A collapsed section with a title and a one-line summary, split at the first " — " |
| `<!-- list: checklist -->`, `<!-- list: points -->`, `<!-- list: points know -->` before a list | The tutorial's styled lists: requirements to tick off, bullet points, "things to know" |
| `<!-- list: next-list -->` before a list of `- [**Title**](link) — Description` | Link cards ("Where next", the Guides index) |
| `<!-- table: cmp -->` before a table, optionally `<!-- table-foot: Text -->` right after it | The Rails/CyberTrain comparison table and its foot note. The table has exactly two header cells; keep it in one piece: a blank line inside it splits it |
| ```` ```LANG PLACE ```` | A code block. `LANG` is a [Rouge](https://github.com/rouge-ruby/rouge) lexer name (`ruby`, `erb`, `toml`, `shell`, `text`; one Rouge does not know fails the build); `PLACE`, optional, is the caption: a file (`app/models/article.rb`, `config/routes.rb (excerpt)`) or where it runs (`terminal — blog/`, `output — cybertrain server`) |
| `shell` (or `sh`) and `console` fences | `shell`: every line is a command. `console`: a transcript, where a `$ ` line is a command and the others are its output |
| `[text](other.md#anchor)` | A link to another guide, in the same language, made relative to the page. The anchor must be one of that page's heading ids |
| `[text](site:playground.html)` | A site page that is not built from here (`index.html`, `deploy.html`, `playground.html`, `api/index.html`), from the page's language root (`api/` and `assets/` from the site root). It must exist in `site/` (`api/`, built by YARD, is not checked) |
| `[text](../../examples/blog)` | Any other relative link is a repository path, made a GitHub link (`blob/main/`, `tree/main/` for a directory). It must exist. Relative paths are relative to `docs/guide/`, in the translations too |
| Raw HTML with `markdown="0"` | Only for a one-off that no convention covers (the tutorial's environment-variable table, its animated terminal); the HTML is copied as it is |

`script/guide-pages` fails, listing every problem and writing nothing, on a
broken link, anchor, repository path or `site:` page, a file without exactly
one `# ` title, a heading id used twice, an unclosed code fence, a malformed
step comment, an unknown code language or front matter key, a `path` other
than `tutorial.html` or `guide/<name>.html`, or an image with a relative URL
(images are not supported yet).

## Building and previewing

The build needs Ruby and the `kramdown`, `kramdown-parser-gfm` and `rouge`
gems, at the versions the Gate and Pages workflows pin; the API reference,
optional for a preview, needs `yard` as well:

```sh
gem install kramdown -v "~> 2.5"
gem install kramdown-parser-gfm -v "~> 1.1"
gem install rouge -v "~> 5.1"
gem install yard                      # optional, for script/api-docs
```

```sh
script/api-docs                       # optional: site/api/, so that the API links resolve
script/guide-pages                    # the tutorial and the guides into site/; or: script/guide-pages --out DIR
python3 -m http.server -d site 8000   # http://localhost:8000/tutorial.html
```

The generated files are in `.gitignore`. The Pages workflow
([.github/workflows/pages.yml](../../.github/workflows/pages.yml)) runs both
scripts before each deploy, and the Gate workflow builds the pages into a
temporary directory on every pull request and every push to `main`, with the
generator's tests (`script/guide-pages.d/test/`).

## Translations

Each English file has a translation in `ja/`, `zh/`, `ru/` and `fr/`, with
the same structure and only the prose translated:

- headings, steps, markers, lists and tables as in the English, in the same
  order; the heading text is translated, the ids stay English;
- code blocks unchanged, except `# ` comments, which are translated; ERB
  comments (`<%# … %>`) stay English;
- inline code unchanged;
- app output and UI labels quoted in prose (a button, a menu entry, an error
  message) stay English, in the language's own quotation marks;
- link targets unchanged, anchors included; link text is translated;
- a code caption with a space in it (`terminal — any directory`,
  `config/routes.rb (excerpt)`) may be translated; a bare path
  (`config/app.rb`) may not;
- front matter as in [Front matter](#front-matter).

When an English file changes, change its four translations in the same pull
request. Then, for each, once it matches:

```sh
script/check-guide-i18n --update-sha docs/guide/ja/install.md   # and zh/, ru/, fr/
```

which records the English file's current hash in the translation's
`source_sha256`. `script/check-guide-i18n` (all languages; or
`script/check-guide-i18n ja`) fails when a translation is missing, its hash is
not the English file's, or its front matter keys, headings, steps, markers,
code blocks (comments aside), table rows or link targets differ from the
English; the comment at the top of the script lists what is compared. Prose is
not compared. If you cannot translate, say so in the pull request and leave
the English change; a maintainer will follow up. The pull request's Gate check
stays red until the four translations are updated in it, and merging it
without them would block the Pages deploys.

The check runs in `script/gate`, and so in the pre-commit hook, whenever a
file under `docs/guide/` changes; in the Gate workflow; and in the Pages
workflow before the build, so a translation out of step is never deployed.
