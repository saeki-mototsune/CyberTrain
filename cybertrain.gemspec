# The `cybertrain` command as a gem. Only the CLI (`new`, `generate
# scaffold`, `db`, `server`, `build`, `setup`, `doctor`) ships here and runs
# under CRuby; the framework itself is a spin package that `cybertrain new`
# points the app's spin.toml at (the git tag v#{VERSION}), so the two are
# released from the same tag. Spinel is not in the gem either: the CLI
# builds the pinned release into ~/.cybertrain the first time it needs it.
require_relative "cybertrain/version"

Gem::Specification.new do |spec|
  spec.name = "cybertrain"
  spec.version = Cybertrain::VERSION
  spec.authors = ["Saeki Mototsune"]
  spec.summary = "The cybertrain CLI: scaffold Rails-shaped apps for the Spinel AOT Ruby compiler"
  spec.description = <<~TEXT
    cybertrain is a Rails-shaped web framework written for Spinel, which
    compiles an application into a native binary. This gem installs the
    `cybertrain` command (`cybertrain new`, `generate scaffold`,
    `db migrate`, `server`, `build`). The first command that needs Spinel
    builds the pinned release into ~/.cybertrain (a C compiler, make, git,
    curl and the SQLite headers are required); `cybertrain doctor` checks.
  TEXT
  spec.license = "MIT"
  spec.homepage = Cybertrain::REPOSITORY
  spec.metadata = {
    "source_code_uri" => Cybertrain::REPOSITORY,
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.2"

  # The CLI and exactly what it requires (checked by CI: see
  # .github/workflows/ci.yml). The rest of cybertrain/ is the framework,
  # which only compiles under Spinel.
  spec.files = [
    "cybertrain/version.rb",
    "cybertrain/cli.rb",
    "cybertrain/cli/new_app.rb",
    "cybertrain/cli/scaffold.rb",
    "cybertrain/cli/templates.rb",
    "cybertrain/cli/build.rb",
    "cybertrain/cli/toolchain.rb",
    "cybertrain/generator/inflector.rb",
    "cybertrain/ident.rb",
    "exe/cybertrain",
    "README.md"
  ]
  spec.require_paths = ["."]
  spec.bindir = "exe"
  spec.executables = ["cybertrain"]
end
