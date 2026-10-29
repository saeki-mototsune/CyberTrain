# Site refinement: implementation plan

Spec: `docs/superpowers/specs/2026-10-29-site-refinement-design.md`.
Branch: `worktree-site-refinement` (worktree
`.claude/worktrees/site-refinement`). Every task runs in that directory.

Common verification (every task that touches `docs/guide/` or the
generator; the gems are installed):

```sh
for t in script/guide-pages.d/test/*_test.rb; do ruby -Iscript/guide-pages.d/lib "$t" || exit 1; done
script/guide-pages --out /tmp/site-check      # fails on a broken link, anchor, fence, marker
script/gate                                   # whitespace, newline, YAML, i18n hashes (red until Phase C)
```

Phases run in order; tasks inside a phase run in parallel because they
touch disjoint files.

## Phase A — English sources (parallel)

### A1 · how-it-works, models, requests (opus)

Files: `docs/guide/how-it-works.md`, `docs/guide/models.md`,
`docs/guide/requests.md`, `docs/benchmark.md` (one link).

1. Rewrite `how-it-works.md` per spec 3.4: intro (two sentences, then the
   performance pointer to `site:index.html#performance` and
   `../benchmark.md`); `##` sections: Build-time code generation, Views are
   interpreted, The HTTP server, SQLite via FFI, The development loop,
   Differences from Rails. The table keeps every row in order under
   `<!-- table: cmp -->` with `<!-- table-foot: Not exhaustive — docs/design.md §8 is the fuller record. -->`;
   the transactions, column-name, `pluck`/`upsert` (keep: it is short enough
   once trimmed), `order`/query and gzip rows become one sentence plus a link.
   Remove the Performance section. Front matter: `description`.
2. Append to `models.md`: `## Transactions`, `## Column names`,
   `## Ordering`, carrying the moved text (lightly re-paragraphed to the
   rules in spec 3.2; code blocks kept).
3. Append to `requests.md`: `## Query strings and bodies`.
4. `docs/benchmark.md` keeps its link (anchor unchanged). README is A2's.

Verify: common checks; `grep -c '^## ' docs/guide/how-it-works.md` is 6;
no line before the first `##` other than front matter, title, intro
paragraph(s) under three sentences plus the pointer sentence.

### A2 · install, tutorial, index, README links, guide README (opus)

Files: `docs/guide/install.md`, `docs/guide/tutorial.md`,
`docs/guide/index.md`, `docs/guide/README.md`, `README.md`,
`playground/README.md`.

1. Rewrite `install.md` per spec 3.4 (title "Installing"). Moved-in text:
   the `<details>` body from tutorial step 00 (Spinel install), home §03's
   closing paragraph (upgrading: update the gem, point `spin.toml` at the
   new tag, `cybertrain spin lock`, `cybertrain spin run gen`). Removed:
   the playground section (replaced by a `> [!NOTE]` under the intro), the
   quick-start figure beyond `gem install cybertrain` / `cybertrain doctor`,
   the self-test paragraph, the checkout paragraph.
2. `tutorial.md`: step 00 and step 01 and the Differences section per spec
   3.4; "Things to know" gets a final bullet
   `- The full list of differences from Rails: [Differences from Rails](how-it-works.md#differences-from-rails).`
3. `index.md`: Installing → "Requirements, the `cybertrain` command, how
   Spinel and the framework are installed"; How it works → "Build-time code
   generation, interpreted views, the server, the development loop, and the
   full list of differences from Rails".
4. `README.md`: the playground link → `playground.html`; the "numbers" link →
   `index.html#performance`; the documentation table's Installing and How it
   works rows reworded as in 3.
5. `playground/README.md` line 9: link `playground.html` on the site instead
   of `install.md#try-it-in-the-browser` (or drop the anchor).
6. `docs/guide/README.md`: a "Writing a guide" section with the seven rules
   of spec 3.2, placed before "Building and previewing".

Verify: common checks; every anchor used (`#requirements`,
`#the-cybertrain-command`, `#how-spinel-is-installed`,
`#the-gem-and-the-framework`) exists in the built `guide/install.html`.

### A3 · template-language headings (sonnet)

File: `docs/guide/template-language.md`.

Remove the typed numbers from the ten `##` headings (`## 1. What is, and
is not, Ruby here` → `## What is, and is not, Ruby here`); move the
file-role table into `<details><summary>Where this lives in the source — the eight files of the template pipeline</summary>` at
the end of the first section's text, keeping the table intact (a blank line
before and after it inside the details). Change nothing else.

Verify: common checks; `grep -n '^## [0-9]' docs/guide/template-language.md`
is empty; the built page's contents list has ten entries.

### A4 · renderer, CSS, layout nav (opus)

Files: `script/guide-pages.d/lib/render.rb`,
`script/guide-pages.d/test/render_test.rb`, `site/assets/style.css`,
`script/guide-pages.d/layout.html.erb`.

1. `render.rb` `convert_table`: for the default kind, wrap kramdown's table
   in `<div class="table-scroll">…</div>`. A test asserts the wrapper and
   that a `cmp` table is unchanged.
2. `style.css`: after the `.doc-body` rules, add styles for
   `.doc-body .table-scroll table` (not `.cmp`, not `.env`): `width: 100%;
   border-collapse: collapse; table-layout: auto; font-size: 15px;
   line-height: 1.5`; `th` left-aligned, mono 11.5px uppercase like `.env th`;
   `td`/`th` `padding: 12px 16px 12px 0; vertical-align: top;
   border-bottom: 1px solid var(--line)`; `td:first-child { min-width: 11em;
   color: var(--ink) }`; `td code { color: var(--ink) }`. Keep the existing
   mobile `.env` block untouched.
3. `layout.html.erb`: the "How it works" nav entry → `<%= home %>guide/how-it-works.html`.

Verify: generator tests pass; build; open the built
`guide/configuration.html` (has plain tables) in Playwright and screenshot.

### A5 · home page English, site nav, site README (opus)

Files: `site/index.html`, `site/deploy.html`, `site/playground.html`,
`site/README.md`.

1. `index.html` per spec 3.3. Keep every `id`, class and the markup pattern
   of each section (the translation checker compares structure, so the
   four translations will mirror exactly what is left). Removing §07 means
   removing its whole `<section>`; renumber `.sec-num` text 01–06 and the
   `sec-label`s stay. Any link to `#requirements` on the page → `guide/install.html#requirements`.
2. In all three English pages: the nav "How it works" href →
   `guide/how-it-works.html`.
3. `site/README.md`: the Performance paragraph says §05, not §06; add the
   sentence that the home page carries summaries only and links the
   guides for detail.

Verify: visible word count under 1,500
(`sed -e 's/<script[^>]*>.*<\/script>//g' site/index.html | sed 's/<[^>]*>/ /g' | wc -w`);
every relative href in the three pages resolves against the built tree
(`script/guide-pages --out /tmp/site-check`, then check each `href` that is
not `http`/`#`, with `guide/`/`tutorial.html` resolved in `/tmp/site-check`).

### A-review · English review (opus)

Read the spec and the diff of Phase A; check the success criteria of spec
§4 that do not need translations; report defects to fix before Phase C.

## Phase C — translations (parallel, one agent per language)

Agent per language: ja (opus), zh (sonnet), ru (sonnet), fr (sonnet).

Files per language L: `docs/guide/L/{how-it-works,install,tutorial,models,requests,template-language,index}.md`,
`site/L/{index,deploy,playground}.html`.

1. For each guide: make the L file mirror the new English structure
   (headings, markers, code blocks, table rows, link targets), reusing the
   existing L prose for every sentence that survived in English and
   translating moved or new sentences; follow `docs/guide/README.md`
   "Translations". Then `script/check-guide-i18n --update-sha docs/guide/L/<name>.md`.
2. For each site page: apply the same structural change the English page
   got (`git diff main -- site/index.html` shows it), with the L prose.
3. Verify: `script/check-guide-i18n L` and `script/check-site-i18n L` pass;
   `script/guide-pages --out /tmp/site-L` builds.

## Phase D — verification and delivery

1. `script/gate`, `script/check-guide-i18n`, `script/check-site-i18n`,
   generator tests, full build.
2. Screenshots of `index.html`, `guide/how-it-works.html`,
   `guide/install.html`, `guide/configuration.html` (table styling),
   `ja/guide/how-it-works.html` into the scratchpad.
3. Branch review (opus): spec compliance, broken links, lost facts (every
   fact removed from a page must exist on its canonical page).
4. Commit per phase; push; open the PR.
