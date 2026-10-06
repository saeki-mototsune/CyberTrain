# Documentation only: never required, never compiled. Gives the Cybertrain
# namespace its page text (its real definition is spread over every file in
# cybertrain/).

# The framework's namespace. An application reaches it in three places:
#
# - its classes, through `ApplicationController < Cybertrain::Controller`
#   and the models `spin run gen` derives from {Cybertrain::Model};
# - `config/app.rb`, through {Cybertrain.configure} and {Cybertrain.url_root=};
# - `config/routes.rb`, through {Cybertrain::Routes.draw}.
#
# See the {file:docs/api/README.md overview} for where each part of the API
# is documented.
# @api public
module Cybertrain
  # Build-time code: `spin run gen` runs `config/routes.rb` against
  # {Gen::Mapper} and writes `gen/`. The rest of it is internal.
  # @api public
  module Gen
  end

  # The table definitions of migrations and `db/schema.rb`: {Schema::TableDef}.
  # @api public
  module Schema
  end

  # Migrations: {Migration::Base}.
  # @api public
  module Migration
  end
end

# The helpers `spin run gen` writes into an application's `gen/routes.rb`:
# {Gen::UrlHelpers}.
# @api public
module Gen
end
