---
source_sha256: f33d41101fb56e6a4ccb2fd65374062a590ba781adb2baf79d57aef2a6aefb2c
---
# Assets

Feuilles de style, images et JavaScript selon l’organisation de Rails&nbsp;8&nbsp;: `spin run gen` les place avec une empreinte (digest) dans `public/assets/`, réécrit les références `url()` du CSS, et compile le manifeste et l’import map dans le binaire&nbsp;; les helpers de balises écrivent les chemins avec empreinte, et le serveur les met en cache pour un an.

## Sources et chemins logiques

```text app/
app/assets/stylesheets/application.css    application.css
app/assets/images/logo.svg                logo.svg
app/javascript/application.js             application.js
app/javascript/controllers/hello.js       controllers/hello.js
vendor/javascript/chart.js                chart.js
```

Chaque répertoire placé directement sous `app/assets/` est une racine, tout comme `app/javascript/` et `vendor/javascript/`&nbsp;: le chemin logique d’un fichier est son chemin sous sa racine (la colonne de droite ci-dessus), c’est-à-dire le nom que prennent les helpers. Un chemin logique trouvé sous deux racines arrête `spin run gen`, qui nomme les deux fichiers. Les fichiers cachés (`.keep`) et les répertoires liés symboliquement sous une racine sont ignorés, mais une racine qui est elle-même un lien symbolique (`app/assets`, `app/javascript`, `vendor/javascript`) arrête gen, qui la nomme&nbsp;; un fichier lié symboliquement est lu s’il reste dans son arborescence, et un lien qui mène en dehors, ou nulle part, arrête gen. Un chemin contenant une espace ou un caractère de contrôle est refusé. Une construction CSS séparée (Sass, Tailwind) peut écrire dans `app/assets/builds/`, une racine comme les autres.

## Empreintes et conservation

`spin run gen` écrit chaque fichier sous la forme `public/assets/<nom>-<empreinte>.<ext>`, l’empreinte étant les 8 premiers caractères hexadécimaux du SHA-256 de son contenu (l’empreinte courte de Propshaft)&nbsp;: `application.css` devient `application-1a2b3c4d.css`. `gen/assets.rb` contient la table des chemins logiques vers les chemins avec empreinte sous la forme d’un `case` généré, l’import map et ses préchargements, et est compilé dans le binaire, si bien que le programme n’a besoin que de `public/assets/` à côté de lui. Un fichier modifié reçoit un nouveau nom&nbsp;; l’ancien n’est jamais réécrit.

Les anciennes empreintes sont conservées pour qu’une page chargée avant un déploiement, ou un ancien processus encore en marche pendant un déploiement progressif, trouve ce que son HTML nomme&nbsp;: pour chaque chemin logique, gen garde l’empreinte actuelle et les deux précédentes et supprime les fichiers plus anciens, comme `assets:clean` de Propshaft garde trois versions. L’historique est `public/assets/.manifest` (une ligne par chemin logique&nbsp;: le chemin, puis jusqu’à trois empreintes), si bien que `gen/assets.rb` reste une fonction pure des sources et que `spin run gen -- --check` ne compare que lui. `public/assets/` est un produit de la construction&nbsp;: le `.gitignore` qu’écrit `cybertrain new` contient `/public/assets/`, et `cybertrain build` et la construction de l’image exécutent gen.

La boucle de développement surveille `app/assets/**`, `app/javascript/**` et `vendor/javascript/**`, si bien qu’une feuille de style enregistrée relance gen et que la page suivante charge la nouvelle empreinte.

## `url()` en CSS

Un `url()` dans une feuille de style qui nomme un asset est réécrit vers le chemin avec empreinte, comme le fait le compilateur de Propshaft, et une feuille de style reçoit son empreinte après les fichiers qu’elle nomme, si bien que sa propre empreinte change quand une image qu’elle utilise change&nbsp;:

```css
.brand { background: url("logo.svg") no-repeat; }
/* in public/assets/application-1a2b3c4d.css: */
.brand { background: url("/assets/logo-8177afd7.svg") no-repeat; }
```

Le chemin est résolu par rapport au répertoire **logique** de la feuille de style (un `/` initial part des racines)&nbsp;: depuis `application.css`, `logo.svg` est le chemin logique `logo.svg`, et `../images/logo.svg` remonte au-dessus des racines et n’est pas un asset. Un `?query` ou un `#fragment` est conservé après le chemin avec empreinte. Les cibles `data:`, `http:`, `https:`, `//`, `#` et `%23` sont laissées telles quelles&nbsp;; toute autre cible qui n’est pas un asset est laissée telle qu’écrite, avec un avertissement de gen. Un cycle de feuilles de style qui se nomment l’une l’autre arrête gen (`CSS url() cycle: a.css -> b.css -> a.css`).

## Helpers

```erb
<%= stylesheet_link_tag "application" %>        <%# <link rel="stylesheet" href="/assets/application-1a2b3c4d.css"> %>
<%= javascript_include_tag "legacy" %>          <%# <script src="/assets/legacy-5e6f7a8b.js"></script> %>
<%= image_tag "logo.svg", alt: "CyberTrain", size: "32x32" %>
<%= asset_path "logo.svg" %>                    <%# /assets/logo-8177afd7.svg %>
```

`stylesheet_link_tag` ajoute `.css` et `javascript_include_tag` `.js` quand le nom n’en a pas&nbsp;; les deux prennent `nonce: true`, et `stylesheet_link_tag` prend `media:`. Une URL avec un schéma (ou `//`, `data:`) est écrite telle quelle, de même qu’un chemin qui commence par `/`. Un nom logique inconnu lève `Cybertrain::Assets::UnknownAsset` en développement et en test (`asset "logo.png" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)`)&nbsp;; la production le journalise une fois et écrit `/assets/<nom>`. Les signatures complètes sont dans [le langage de templates](template-language.md#helpers-and-the-form-builder).

## L’import map

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
pin "chart", to: "chart.js", preload: false
pin_all_from "app/javascript/controllers", under: "controllers"
```

gen lit le fichier comme du texte, sans jamais l’exécuter&nbsp;: `pin name, to:, preload:` et `pin_all_from dir, under:, preload:`, les commentaires et les lignes vides&nbsp;; toute autre ligne arrête gen. Un `to:` sans schéma est un chemin logique d’asset, et un pin sans `to:` nomme `<name>.js`&nbsp;; `pin_all_from` épingle chaque fichier `.js` sous le répertoire comme `<under>/<son chemin sans .js>`, un `index.js` comme `under` lui-même. `preload:` vaut true par défaut (importmap-rails&nbsp;2). Dans le layout,

```erb
<%= javascript_importmap_tags %>
```

écrit le `<script type="importmap">`, un `<link rel="modulepreload">` par pin préchargé et `<script type="module">import "application"</script>`, chacun avec le nonce de la requête quand une [Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) s’applique. Il n’y a pas de `bin/importmap pin`&nbsp;: copiez une bibliothèque dans `vendor/javascript/` et épinglez-la, ou épinglez une URL. Turbo n’est pas fourni.

## Service des fichiers

Le middleware des fichiers statiques sert un fichier sous `/assets/` dont le nom porte une empreinte écrite par gen (une actuelle, tirée de `gen/assets.rb`, ou une conservée, tirée de `public/assets/.manifest`, lu au démarrage) avec `Cache-Control: public, max-age=31536000, immutable`&nbsp;; il n’a pas besoin d’ETag, puisque le fichier ne change jamais. Tout le reste de `public/`, y compris un fichier sans empreinte qu’une application garde sous `public/assets/`, garde `max-age=3600`. Un fichier caché sous `/assets` (`.manifest`, le fichier temporaire d’une exécution de gen interrompue) n’est pas servi&nbsp;; un fichier caché ailleurs dans `public/` (`/.well-known/...`) l’est. Un fichier dont le chemin réel sort de `public/` n’est pas servi&nbsp;: un déploiement qui relie `public/assets` par un lien symbolique vers un répertoire hors de `public/` (les répertoires partagés de Capistrano) le monte ou le monte en bind à cet endroit à la place. Un reverse proxy qui sert lui-même `public/` envoie ses propres en-têtes&nbsp;; donnez-y à `/assets/` la même mise en cache immuable d’un an.

## Déplacer `public/style.css`

Une application créée avant l’existence des assets sert `public/style.css` comme un fichier ordinaire, et continue de fonctionner. Pour le déplacer&nbsp;:

```shell terminal — le répertoire de l’application
mkdir -p app/assets/stylesheets app/javascript
git mv public/style.css app/assets/stylesheets/application.css
echo '/public/assets/' >> .gitignore
```

Dans `app/views/layouts/application.html.erb`, remplacez la ligne `<link rel="stylesheet" href="/style.css">` par `<%= stylesheet_link_tag "application" %>` (et ajoutez `<%= csp_meta_tag %>` et `<%= javascript_importmap_tags %>` une fois que `config/importmap.rb` existe), déplacez les images que nomme la feuille de style dans `app/assets/images/` avec des références du type `url("logo.svg")`, puis lancez `spin run gen`.

## L’`asset_path` de Kamal

Un déploiement qui construit une image neuve (Kamal, Docker) n’emporte que les empreintes actuelles. Le `config/deploy.yml` qu’écrit `cybertrain new` contient

```yaml
asset_path: /app/public/assets
```

si bien que Kamal fait passer les fichiers de la version précédente dans le nouveau conteneur pendant la bascule&nbsp;: une page chargée avant le déploiement trouve encore le CSS et le JavaScript que son HTML nomme. Ajoutez la ligne à un `config/deploy.yml` plus ancien.
