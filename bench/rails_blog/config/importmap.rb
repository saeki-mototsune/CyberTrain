# Pin npm packages by running ./bin/importmap

# app/javascript/application.js, and Turbo (turbo-rails' own build, which
# makes <turbo-cable-stream-source> live over Action Cable). examples/blog
# pins Turbo from jsDelivr and has no Stimulus.
pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
