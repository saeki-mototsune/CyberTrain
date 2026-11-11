# Assets

Stylesheets, images and JavaScript in Rails 8's layout: `spin run gen`
digests them into `public/assets/`, rewrites the `url()` references in CSS,
and compiles the manifest and the import map into the binary; the tag
helpers write the digested paths, and the server caches them for a year.

## Sources and logical paths

```text app/
app/assets/stylesheets/application.css    application.css
app/assets/images/logo.svg                logo.svg
app/javascript/application.js             application.js
app/javascript/controllers/hello.js       controllers/hello.js
vendor/javascript/chart.js                chart.js
```

Every directory directly under `app/assets/` is a root, and so are
`app/javascript/` and `vendor/javascript/`: a file's logical path is its
path below its root (the right-hand column above), which is the name the
helpers take. A logical path found under two roots stops `spin run gen`,
naming both files. Dotfiles (`.keep`) and symlinked directories under a root are
skipped, but a root that is itself a symlink (`app/assets`, `app/javascript`,
`vendor/javascript`) stops gen, which names it; a symlinked file is read when it stays inside its tree, and one
that leads outside it, or nowhere, stops gen. A path holding a space or a
control character is refused. A separate CSS build (Sass, Tailwind) may
write into `app/assets/builds/`, which is a root like any other.

## Digests and retention

`spin run gen` writes each file as `public/assets/<name>-<digest>.<ext>`,
the digest being the first 8 hex characters of the SHA-256 of its content
(Propshaft's short digest): `application.css` becomes
`application-1a2b3c4d.css`. `gen/assets.rb` holds the logical-to-digested
table as a generated `case`, the import map and its preloads, and is
compiled into the binary, so the program needs only `public/assets/` beside
it. A changed file gets a new name; the old one is never rewritten.

Old digests are kept so that a page loaded before a deploy, or an old
process still running during a rolling deploy, finds what its HTML names:
for each logical path gen keeps the current digest and the two before it
and deletes older files, as Propshaft's `assets:clean` keeps three
versions. The history is `public/assets/.manifest` (one line per logical
path: the path, then up to three digests), so `gen/assets.rb` stays a pure
function of the sources and `spin run gen -- --check` compares only it.
`public/assets/` is build output: the `.gitignore` that `cybertrain new`
writes lists `/public/assets/`, and `cybertrain build` and the image build
run gen.

The development loop watches `app/assets/**`, `app/javascript/**` and
`vendor/javascript/**`, so a saved stylesheet re-runs gen and the next page
loads the new digest.

## CSS `url()`

A `url()` in a stylesheet that names an asset is rewritten to the digested
path, as Propshaft's compiler does, and a stylesheet is digested after the
files it names, so its own digest changes when an image it uses does:

```css
.brand { background: url("logo.svg") no-repeat; }
/* in public/assets/application-1a2b3c4d.css: */
.brand { background: url("/assets/logo-8177afd7.svg") no-repeat; }
```

The path is resolved against the stylesheet's **logical** directory (a
leading `/` starts from the roots): from `application.css`, `logo.svg` is
the logical `logo.svg`, and `../images/logo.svg` climbs above the roots and
is not an asset. A `?query` or `#fragment` is kept after the digested path.
`data:`, `http:`, `https:`, `//`, `#` and `%23` targets are left alone; any
other target that is not an asset is left as written, with a warning from
gen. A cycle of stylesheets naming each other stops gen
(`CSS url() cycle: a.css -> b.css -> a.css`).

## Helpers

```erb
<%= stylesheet_link_tag "application" %>        <%# <link rel="stylesheet" href="/assets/application-1a2b3c4d.css"> %>
<%= javascript_include_tag "legacy" %>          <%# <script src="/assets/legacy-5e6f7a8b.js"></script> %>
<%= image_tag "logo.svg", alt: "CyberTrain", size: "32x32" %>
<%= asset_path "logo.svg" %>                    <%# /assets/logo-8177afd7.svg %>
```

`stylesheet_link_tag` adds `.css` and `javascript_include_tag` `.js` when
the name lacks it; both take `nonce: true`, and `stylesheet_link_tag` takes
`media:`. A URL with a scheme (or `//`, `data:`) is written as given, and so
is a path starting with `/`. An unknown logical name raises
`Cybertrain::Assets::UnknownAsset` in development and test (`asset
"logo.png" is not in app/assets, app/javascript or vendor/javascript (run
spin run gen)`); production logs it once and writes `/assets/<name>`. The
full signatures are in [the template language](template-language.md#helpers-and-the-form-builder).

## The import map

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
pin "chart", to: "chart.js", preload: false
pin_all_from "app/javascript/controllers", under: "controllers"
```

gen reads the file as text, never running it: `pin name, to:, preload:` and
`pin_all_from dir, under:, preload:`, comments and blank lines; any other
line stops gen. A `to:` without a scheme is a logical asset path, and a pin
without `to:` names `<name>.js`; `pin_all_from` pins every `.js` file
below the directory as `<under>/<its path without .js>`, an `index.js` as
`under` itself. `preload:` is
true by default (importmap-rails 2). In the layout,

```erb
<%= javascript_importmap_tags %>
```

writes the `<script type="importmap">`, a `<link rel="modulepreload">` per
preloaded pin and `<script type="module">import "application"</script>`,
each with the request's nonce when a
[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)
applies. There is no `bin/importmap pin`: copy a library into
`vendor/javascript/` and pin it, or pin a URL. Turbo is not bundled.

## Serving

The static-file middleware serves a file under `/assets/` whose name
carries a digest gen wrote (a current one, from `gen/assets.rb`, or a kept
one, from `public/assets/.manifest`, read at boot) with `Cache-Control:
public, max-age=31536000, immutable`; it needs no ETag, as the file never
changes. Everything else in `public/`, an undigested file an application
keeps under `public/assets/` included, keeps `max-age=3600`. A dotfile under `/assets` (`.manifest`, the temporary
file of a gen run that crashed) is not served; a dotfile elsewhere in `public/`
(`/.well-known/...`) is. A file whose
real path leaves `public/` is not served: a deploy that symlinks
`public/assets` to a directory outside `public/` (Capistrano's shared
directories) mounts or bind-mounts it there instead. A reverse proxy that
serves `public/` itself sends its own headers; give `/assets/` the same
year-long, immutable caching there.

## Moving `public/style.css`

An application created before assets existed serves `public/style.css`
as a plain file, and keeps working. To move it:

```shell terminal — the app's directory
mkdir -p app/assets/stylesheets app/javascript
git mv public/style.css app/assets/stylesheets/application.css
echo '/public/assets/' >> .gitignore
```

In `app/views/layouts/application.html.erb`, replace the `<link
rel="stylesheet" href="/style.css">` line with
`<%= stylesheet_link_tag "application" %>` (and add `<%= csp_meta_tag %>`
and `<%= javascript_importmap_tags %>` once `config/importmap.rb` exists),
move the images the stylesheet names into `app/assets/images/` with
`url("logo.svg")`-style references, then run `spin run gen`.

## The Kamal `asset_path`

A deploy that builds a fresh image (Kamal, Docker) carries only the current
digests. The `config/deploy.yml` that `cybertrain new` writes has

```yaml
asset_path: /app/public/assets
```

so Kamal bridges the previous release's files into the new container for
the switch-over: a page loaded before the deploy still finds the CSS and
JavaScript its HTML names. Add the line to an older `config/deploy.yml`.
