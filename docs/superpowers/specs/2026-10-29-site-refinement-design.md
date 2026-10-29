# Site refinement: one home per topic, lighter pages

Date: 2026-10-29. Scope: the published site (`site/` and the pages
`script/guide-pages` builds from `docs/guide/`), in all five languages.

## 1. The problem

The guides under `docs/guide/` were added on 2026-10-28 (PR #103, #104) by
moving the README's reference material and the old YARD guides into Markdown
that the site renders. Two things went wrong for the reader:

**The same facts are now on two or three pages.** Counted on the English
pages:

| Topic | Copies today |
|---|---|
| The Rails/CyberTrain differences table | home §05 (8 rows), tutorial "Differences from Rails" (16 rows), how-it-works (38 rows) |
| Requirements (Ruby, Spinel, cc, SQLite, zlib, OpenSSL) | home §07, tutorial step 00, install "Requirements" |
| The seven quick-start commands | home hero, tutorial step 01, install "Installing the CLI" |
| The `cybertrain` command list (12 bullets) | tutorial step 01, install "Installing the CLI" |
| How Spinel is installed (`~/.cybertrain`, `PATH`, `CYBERTRAIN_HOME`) | tutorial step 00 `<details>`, install (three paragraphs), home §03 and §07 |
| The playground (what opens, quota, trust prompt, Docker) | playground page, install "Try it in the browser" |
| Build-time generation, interpreted views, the dev loop | home §04 (five 60–100-word steps), how-it-works, tutorial "Things to know" |
| Performance | home §06 (bars, tiles, 200-word note), how-it-works "Performance" (table), docs/benchmark.md |
| Framework vs CLI, upgrading an app | home §03, install prose |

**The generated pages are walls of text.** `how-it-works.md` opens with 90
lines and no `##` heading: the renderer shows the first paragraph as the
page intro and the other five bold-led paragraphs as an unsectioned 600-word
block beside a contents list of two entries. Its differences table is a
plain Markdown table, which the site has no CSS for, so it renders with
browser defaults: a 20%-wide first column and cells of up to 190 words.
`install.md` has 200-word paragraphs; the tutorial's step 01 is a
12-bullet command reference inside a tutorial.

The home page is 2,544 words. It explains how the framework works, the
differences, the requirements and the Spinel install in full instead of
pointing at the pages that now exist for them.

## 2. What readable technical sites do

The structure this design follows is the one the well-read framework sites
(Rails, Astro, Vite, Hono, Bun, Deno, Tailwind) and the Diátaxis
documentation framework share:

- **The landing page sells and routes; it does not document.** A one-line
  value proposition, one install command, two calls to action, three to
  eight short value propositions or feature tiles, one code sample, a
  headline number with a link to the full figures, and a closing call to
  action. 500 to 1,200 words. Every deeper claim is a link.
- **Each fact has one canonical page.** Other pages carry at most a
  one-sentence summary and a link to it. A reader who lands on any page is
  one click from the full answer and never finds two versions of it.
- **Four kinds of documentation page, kept apart** (Diátaxis): a tutorial
  (learning by doing, one path, no digressions), how-to guides (one task
  each), reference (tables, complete, dry), explanation (how and why it
  works). Mixing them makes a page long: a tutorial step that includes a
  command reference, or an explanation that includes a benchmark table.
- **A page is scannable:** a two-sentence intro, a contents list, `##`
  sections of a few hundred words, `###` within them, a code block or
  list every few paragraphs, short table cells, and collapsed sections for
  detail that most readers skip.

## 3. Design

### 3.1 One canonical home per topic

| Topic | Canonical page and section | Everywhere else |
|---|---|---|
| Requirements | `install.md#requirements` | Home: the one-line hero note (exists). Tutorial step 00: a short checklist without the Spinel `<details>`; "the full list and what is optional: Requirements". |
| Installing the CLI, the quick start | Tutorial step 01 (the seven commands, the tutorial's own path). The one exception to "one home": the home hero shows the same seven, because a landing page's one command block is what it exists for; both copies are taken from README.md's quick start, which `site/README.md`'s content rule already requires, so they cannot drift apart silently | `install.md`: `gem install cybertrain` and `cybertrain doctor` only, then a link to the tutorial |
| The `cybertrain` command reference | `install.md#the-cybertrain-command` | Tutorial step 01: one sentence and a link |
| How Spinel is installed, `PATH`, `CYBERTRAIN_HOME`, `CYBERTRAIN_SPINEL_HOME` | `install.md#how-spinel-is-installed` | Tutorial step 00: drop the `<details>`, one sentence and a link. Home §03/§07: dropped (see 3.3) |
| The gem vs the framework package, `spin.toml`, upgrading an app | `install.md#the-gem-and-the-framework` | Home §03: two cards with two facts each and a link |
| The playground | `site/playground.html` | `install.md`: a NOTE under the intro, two sentences, linking `site:playground.html`. README: link the playground page instead of the install anchor |
| Build-time generation, views, server, SQLite, dev loop | `how-it-works.md`, one `##` each | Home §04: the diagram and five steps of one or two sentences each, then a link. Tutorial "Things to know": unchanged (it is a short list) |
| Transactions | `models.md#transactions` (moved from how-it-works) | how-it-works differences row: one sentence and a link |
| Column names and reserved words | `models.md#column-names` (moved from the differences row) | differences row: one sentence and a link |
| `order`, `order_sql`, allowlists | `models.md#ordering` (moved from the differences row) | differences row: one sentence and a link |
| Query strings, malformed input, gzip bodies | `requests.md#query-strings-and-bodies` (moved from the differences rows) | differences rows: one sentence and a link |
| The differences table | `how-it-works.md#differences-from-rails`, every cell under about 30 words | Home §05: the 8-row condensed table, unchanged, with its "full table" link pointed at the guide (it points at the README, which no longer has one). Tutorial: the "Differences from Rails" section removed; "Things to know" ends with a link to the full table |
| Performance | Home §06 (the bars and tiles) and `docs/benchmark.md` (method and every number) | `how-it-works.md`: the Performance section removed; two sentences at the end of the intro with both links. README's "numbers" link: the home anchor |
| Contributor-only material in `install.md` (the framework's own `spin test`, `script/regen-snapshot`, running the CLI from a checkout) | `CONTRIBUTING.md` (already there) | `install.md`: removed |

### 3.2 Readability rules for a guide source

These apply to every file under `docs/guide/` that this change touches and
are recorded in `docs/guide/README.md` ("Writing a guide") for later ones.

1. After `# Title`, one paragraph of one to three sentences (the page intro),
   then the first `##`. Nothing else before the first `##`.
2. A `##` section holds under about 400 words of prose; past that, split
   with `###` or move detail into a `<details><summary>Title — summary</summary>`.
3. No bold-led paragraphs as pseudo-headings (`**Topic.** …`). A topic that
   deserves a lead is a `###`.
4. A paragraph runs at most about 120 words; a list of three or more
   parallel facts is a list.
5. A table cell holds under about 30 words. A longer explanation goes into a
   section of the relevant guide and the cell links to it.
6. No numbers typed into headings (`## 1. Tags`): the contents list numbers
   sections already.
7. A page's title and intro say what the page is for; the Guides index entry
   says the same in one line.

### 3.3 The home page (`site/index.html`), English

Sections stay in this order; the numbers in `.sec-num` renumber 01–06.

| Section | Change |
|---|---|
| Hero, who it is for | Unchanged |
| 01 The code you write | Unchanged |
| 02 What works today | Unchanged |
| 03 Framework and CLI | Each card keeps "What is in it" and "How you get it" and loses "Where it runs" and "In dist/blog". The closing paragraph (same tag, how to upgrade) becomes one sentence: "Both are released from the same tag; `install.md#the-gem-and-the-framework` says how an app moves to a new release", as a link |
| 04 How it works | Keep the heading, lead and diagram. Each of the five steps: its `h3` and one or two sentences (under 35 words). Drop the terminal figure. Add a link under the steps: "How it works, in full →" to `guide/how-it-works.html` |
| 05 Rails vs CyberTrain | Rows unchanged. The footer link "Full table in the README ↗" becomes "The full table" → `guide/how-it-works.html#differences-from-rails` (internal, no external mark) |
| 06 Performance | Bars, labels and the four tiles unchanged. The note under the tiles cut to: the measurement setup in one sentence, and "The method, every number and how to run it again: docs/benchmark.md" |
| 07 Before you start | Removed. The hero's "before you start" link already goes to `guide/install.html#requirements` |
| Closer | Unchanged |

Target: about 2,100 words of visible text (from about 2,650 by the same
count): what remains is the hero, the code sample, the feature tiles, the
performance figures and one- or two-sentence summaries. Nothing the guides
hold in full is repeated.

The header navigation on every page (`site/*.html`, `site/<lang>/*.html`,
`script/guide-pages.d/layout.html.erb`) points "How it works" at
`guide/how-it-works.html` instead of `index.html#how-it-works`. The home
section keeps its `id="how-it-works"` so old links still land.

### 3.4 The guides, English

**`how-it-works.md`** — intro of two sentences plus the performance pointer;
sections: Build-time code generation (what `gen` reads; what it writes, as a
list of the six files; why `gen/` is committed), Views are interpreted (link
to the template language), The HTTP server, SQLite via FFI (the pool facts as
a list; transactions pointer), The development loop, Differences from Rails
(the table, `<!-- table: cmp -->` so it gets the site's comparison styling,
rows in the same order, long cells replaced by a sentence and a link to the
section that now holds the detail). Front matter `description` updated.

**`install.md`** — title "Installing"; intro; a NOTE pointing at the
playground; sections: Requirements (the list, with prism / OpenSSL /
jemalloc in a `<details>` "Optional packages"), Install the CLI (three lines
and the tutorial link), The `cybertrain` command (the list, unchanged words),
How Spinel is installed (one paragraph; the `PATH` line; a `<details>` for
the two environment variables), The gem and the framework (what `cybertrain
new` writes and pins, `spin lock`, `--skip-spin`/`--path`/`--git`/`--version`,
moving an app to a new release). `playground/README.md` and `docs/guide/README.md`
links updated.

**`tutorial.md`** — step 00 loses the `<details>` and gains one sentence
linking `install.md#how-spinel-is-installed`; step 01 loses the command
list and the two paragraphs around it, keeping the WHY, the figure and one
sentence linking `install.md#the-cybertrain-command`; the "Differences from
Rails" section (`<!-- step + #differences -->`) is removed and "Things to
know" gets a final bullet linking the full table. Front matter and other
steps unchanged.

**`models.md`** — three sections appended: Transactions (the text from
how-it-works, with its code block), Column names (from the differences row),
Ordering (from the differences row: `order` takes columns only, allowlists,
`order_sql`).

**`requests.md`** — one section appended: Query strings and bodies (malformed
escapes and invalid UTF-8 → `QueryMalformed`/400, nesting limits, gzip
bodies → `decoded_body`, `BodyUndecodable`, `BodyTooLarge`, from the
differences rows).

**`template-language.md`** — headings lose their typed numbers; the file
table moves into a `<details>` "Where this lives in the source" at the end
of the intro's section. No other wording changes. Inbound links use the file
name only, so no anchor changes elsewhere.

**`index.md`** — the Installing and How it works entries re-described.

**`configuration.md`, `testing.md`, `background-and-operations.md`,
`external-services.md`** — untouched. They already follow the rules closely
enough, and every English change costs four translations.

### 3.5 Styling for plain tables (no translation cost)

`site/assets/style.css` gains rules for a Markdown table inside
`.doc-body` that is not a `cmp` table: full width, `table-layout: auto`,
15px text, cell padding, a rule between rows, a first column that does not
wrap below about 11em, and an `overflow-x: auto` wrapper that the renderer
adds (`div.table-scroll`, the class the tutorial's environment table already
uses). This is a renderer change in `render.rb` (`convert_table` for the
default kind) with a test in `render_test.rb`.

### 3.6 Translations

Every changed English source changes its `ja/`, `zh/`, `ru/`, `fr/`
counterpart in the same branch, with the same headings, markers, code
blocks, table rows and link targets, and `source_sha256` updated with
`script/check-guide-i18n --update-sha`. Translated prose is taken from the
existing translations wherever the English sentence survived; only moved or
new sentences are translated afresh. The three hand-written site pages are
translated the same way and `script/check-site-i18n` passes.

The tagline and every `<h1>` stay as they are, so the social cards need no
regeneration.

### 3.7 Out of scope

New content, the API reference, `deploy.html` (unchanged apart from the
header's "How it works" entry, which 3.3 changes on every page), the OG
cards, the design of the page shell, and the four guides listed as
untouched.

## 4. Success criteria

- No topic in table 3.1 appears in full on more than its canonical page.
- `script/guide-pages --out DIR` builds with no error; the generator's
  tests pass; `script/check-guide-i18n`, `script/check-site-i18n` and
  `script/gate` pass.
- `how-it-works.html` has six contents entries and no body text before the
  first section; no `##` section on a touched page exceeds about 400 words
  of prose outside code blocks; no table cell exceeds about 30 words.
- The home page's visible English text is about 2,100 words, and no
  section repeats a guide's content beyond a summary.
- Every link on the built English pages resolves (the build checks guide
  links; the site's hand-written links are checked by grep against the
  built tree).
