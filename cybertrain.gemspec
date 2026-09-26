# The `cybertrain` command as a gem. Only the CLI (`new`, `generate
# scaffold`) ships here and runs under CRuby; the framework itself is a spin
# package that `cybertrain new` points the app's spin.toml at (the git tag
# v#{VERSION}), so the two are released from the same tag.
require_relative "cybertrain/version"

Gem::Specification.new do |spec|
  spec.name = "cybertrain"
  spec.version = Cybertrain::VERSION
  spec.authors = ["Saeki Mototsune"]
  spec.summary = "The cybertrain CLI: scaffold Rails-shaped apps for the Spinel AOT Ruby compiler"
  spec.description = <<~TEXT
    cybertrain is a Rails-shaped web framework written for Spinel, which
    compiles an application into a native binary. This gem installs the
    `cybertrain` command (`cybertrain new`, `cybertrain generate scaffold`);
    building and running an application needs Spinel's `spin` on PATH.
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
    "cybertrain/generator/inflector.rb",
    "exe/cybertrain",
    "README.md"
  ]
  spec.require_paths = ["."]
  spec.bindir = "exe"
  spec.executables = ["cybertrain"]
end
