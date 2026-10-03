module Cybertrain
  # The one definition of "a name usable as the application's package name":
  # `cybertrain build`/`server` (CLI::Build.app_name, reading spin.toml) and
  # the compiled app (Application.new(name:), which the development
  # rebuilder shells out with) both ask here, so the rules cannot drift
  # apart. A leaf file with no requires: the CLI (CRuby) and the framework
  # (Spinel) both load it. String methods only, no Regexp, because it
  # compiles under Spinel (see Dev::Rebuilder).
  module AppName
    # "" when name works as a `spin build` target and as the build/bin/<name>
    # path, else the reason (a String on every path, NOTES rules 10/34).
    # Shell safety is not this method's job: both callers quote the name when
    # they build a command ("my-app" and "MyApp" are fine for `spin build`),
    # so only what breaks the target or the path is refused.
    def self.problem(name)
      # An empty name would become an explicit "" argument to spin.
      return "cannot be empty" if name.empty?
      # "." and ".." name build/bin/. and build/bin/.., which exist already
      # (the latter is build/) and only fail later, in assemble's cp.
      return "cannot be '.' or '..'" if name == "." || name == ".."
      # Quoting leaves a leading "-" bare ("-" is in quote_arg's safe set),
      # and even quoted `spin build '-x'` is parsed by spin as an option, not
      # as the package name. Whether spin accepts `--` before the target is
      # unverified, hence a refusal.
      return "cannot start with '-' (spin would read it as an option)" if name.start_with?("-")
      # A "/" would put the binary in a subdirectory of build/bin.
      return "cannot contain '/'" if name.include?("/")
      # Whitespace splits the target in the places that do not quote it, and
      # a newline ends a command line.
      return "cannot contain whitespace" if name.include?(" ") || name.include?("\t") || name.include?("\n") || name.include?("\r")

      ""
    end
  end
end
