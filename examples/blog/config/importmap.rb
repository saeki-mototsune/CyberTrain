# Pins for the import map (javascript_importmap_tags in the layout): a
# logical name from app/javascript, or a URL. Turbo is one pinned release
# from jsDelivr; to serve it yourself, copy turbo.es2017-esm.js into
# vendor/javascript/ and pin "@hotwired/turbo", to: "turbo.es2017-esm.js".
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
