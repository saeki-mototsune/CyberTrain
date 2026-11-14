# Cybertrain::Runtime -- the one place that writes the process-shared
# settings an Application's boot installs, and the one place that puts them
# back (docs/design.md D64).
#
# The framework keeps four kinds of state, each with one owner:
#
#   configuration   Cybertrain.config (a Config); config/app.rb changes it
#                   until Application#boot, nothing after.
#   registrations   Job handlers, Scheduler tasks, Background services,
#                   Views.helpers_builder / component_builder, Assets'
#                   tables, Config.encryption_required: written when the
#                   program's files load (gen/*.rb, app/**), never by boot,
#                   and never reset.
#   settings        what the modules below hold because the code that reads
#                   them has no Config (the multipart parser, the blob
#                   store, Params, Request, ...): written only by
#                   Runtime.apply, on behalf of the Application that boots;
#                   the last boot wins. Runtime.reset! restores the defaults.
#   resources       the DB pool (DB.connect / DB.disconnect), the server and
#                   the service threads: an Application releases the ones
#                   its own boot or role acquired (Application#shutdown,
#                   the end of #serve / #run_worker / #run_feeds).
#
# One process runs one Application at a time: a second boot takes the
# settings over whole (Runtime.apply writes every one of them, so nothing
# of the first leaks into the second), and only one role runs at once
# (Runtime.enter_role).
require "cybertrain/assets"
require "cybertrain/i18n"
require "cybertrain/blob_store"
require "cybertrain/clock"
require "cybertrain/logger"
require "cybertrain/params"
require "cybertrain/views"
require "cybertrain/http/multipart"
require "cybertrain/http/parameter_filter"
require "cybertrain/http/request"
require "cybertrain/http/response"

module Cybertrain
  # The process-shared settings of the booted Application.
  # @api public
  module Runtime
    # Module-level ivars (spikes/NOTES.md rule 18).
    @applied = 0
    @role = ""

    # The defaults Runtime.reset! restores: what each module holds before
    # any boot. They repeat the modules' own literals, and test/runtime.rb
    # compares the two, so a default changed in one place fails there.
    DEFAULT_LAYOUT = "layouts/application"
    DEFAULT_MAX_UPLOAD_BYTES = 5_242_880
    DEFAULT_MAX_PARTS = 128
    DEFAULT_UPLOAD_ROOT = "storage/uploads"
    DEFAULT_MAX_PAGE = 10_000
    DEFAULT_PERMISSIONS_POLICY = "camera=(), microphone=(), geolocation=()"
    DEFAULT_LOCALE = :en

    # Installs every process-shared setting from `config`, in the order
    # Application#boot always used. Every setting is written on every call,
    # so the settings after a boot depend on that boot's config alone, not
    # on what booted before it.
    # @param config [Config]
    # @return [nil]
    # @api private
    def self.apply(config)
      # The digests public/assets/.manifest keeps are served immutable too
      # (Static); an unknown asset name raises outside production.
      Assets.load_kept(config.public_root)
      Assets.raise_on_unknown = !config.production?
      # The parser and the blob store are reached from places that have no
      # Config. The upload directory is made by the first write, not here,
      # so a read-only deploy still boots.
      Multipart.configure(config.max_upload_bytes, config.max_multipart_parts)
      BlobStore.root = config.upload_root
      Params.max_page = config.max_page
      Request.trusted_proxy = config.trusted_proxy
      Request.trusted_proxies = config.trusted_proxies
      ParameterFilter.names = config.filter_parameters
      Response.default_permissions_policy = config.permissions_policy
      # The level and the format (validation_error has refused unknown ones).
      apply_logging(config)
      # I18n cannot read Config either: the locales and how a missing
      # translation answers.
      I18n.default_locale = config.i18n_default_locale
      I18n.available_locales = config.i18n_available_locales
      I18n.raise_on_missing = config.i18n_raise_on_missing
      I18n.mark_missing = !config.production?
      # Time.zone: the calendar methods, Date.current, l and time_tag read
      # it. validation_error has refused an unknown name before this runs.
      apply_zone(config)
      @applied += 1
      nil
    end

    # Installs the log level on Cybertrain.logger (`:none` as `:error`: no
    # request log, errors still printed) and the line format
    # (Logger.json_lines). {.apply} calls it, and so do a registered command
    # (`Main.command`), `jobs` and `console`, which run without
    # Application#boot, so their lines follow `log_level` and `log_format`
    # too. An unknown level or format is refused as boot refuses it:
    # nothing is changed and the answer is Config#log_error's message,
    # which the caller prints as boot does (`error: ...`) before exiting 1.
    # @param config [Config]
    # @return [String] "" once installed, else why not
    # @api public
    def self.apply_logging(config)
      problem = config.log_error
      return problem unless problem.empty?

      Cybertrain.logger.level = config.log_level == :none ? :error : config.log_level
      Logger.json_lines = config.log_format == :json
      ""
    end

    # Installs `config.time_zone` as `Time.zone` ({Clock.zone}), the one
    # setting a process that does not boot needs too: {.apply} calls it,
    # and so do a registered command (`Main.command`), `jobs` and
    # `console`, which run without Application#boot. An unknown name is
    # refused as boot refuses it: the zone is left as it was and the answer
    # is Config#time_zone_error's message, which the caller prints as
    # boot does (`error: ...`) before exiting 1.
    # @param config [Config]
    # @return [String] "" once the zone is installed, else why not
    # @api public
    def self.apply_zone(config)
      problem = config.time_zone_error
      return problem unless problem.empty?

      Clock.zone = TimeZone.find(config.time_zone)
      ""
    end

    # Puts every setting {.apply} and Application.configure_views write back
    # to its default, as in a process that has not booted: for a test that
    # boots Applications with different configs and wants each case to
    # start from the same state. It leaves the configuration
    # (Cybertrain.config), the registrations (job handlers, helpers,
    # asset tables) and the database connection alone.
    # @return [nil]
    # @api public
    def self.reset!
      Views.reset!
      Assets.forget_kept
      Assets.raise_on_unknown = true
      Multipart.configure(DEFAULT_MAX_UPLOAD_BYTES, DEFAULT_MAX_PARTS)
      BlobStore.root = DEFAULT_UPLOAD_ROOT
      Params.max_page = DEFAULT_MAX_PAGE
      Request.trusted_proxy = false
      Request.trusted_proxies = Array.new(0) { "" }
      ParameterFilter.names = ParameterFilter::DEFAULT_NAMES
      Response.default_permissions_policy = DEFAULT_PERMISSIONS_POLICY
      Cybertrain.logger.level = :info
      Logger.json_lines = false
      I18n.default_locale = DEFAULT_LOCALE
      I18n.available_locales = [DEFAULT_LOCALE]
      I18n.raise_on_missing = false
      I18n.mark_missing = true
      Clock.zone = TimeZone::UTC
      @role = ""
      nil
    end

    # How many times {.apply} has run in this process: 0 until the first
    # boot. A second boot of the same Application counts again.
    # @return [Integer]
    # @api public
    def self.applied
      @applied
    end

    # The settings as one line, for a test to compare two states (and for a
    # bug report): every value {.apply} and Application.configure_views
    # write, in a fixed order, except I18n's four, which I18n answers
    # itself (I18n.default_locale, I18n.available_locales).
    # @return [String]
    # @api public
    def self.describe
      views = Views.engine.nil? ? "none" : "configured"
      "views=#{views} layout=#{Views.layout_name} " \
        "assets_raise=#{Assets.raise_on_unknown} assets_kept=#{Assets.kept_count} " \
        "max_upload_bytes=#{Multipart.max_upload_bytes} max_parts=#{Multipart.max_parts} " \
        "upload_root=#{BlobStore.root} max_page=#{Params.max_page} " \
        "trusted_proxy=#{Request.trusted_proxy} trusted_proxies=#{Request.trusted_proxies.join(",")} " \
        "filter_parameters=#{ParameterFilter.names.join(",")} " \
        "permissions_policy=#{Response.default_permissions_policy} " \
        "log_level=#{Cybertrain.logger.level} log_format=#{Logger.json_lines ? "json" : "text"} time_zone=#{Clock.zone.zone_name}"
    end

    # Claims the process for a role (`server`, `worker`, `feeds`): one role
    # runs at a time, since each owns the process-wide service threads
    # (Job, Scheduler, Background) and the signal handlers.
    # @param role [String]
    # @return [String] "" when the claim succeeded, else what to report
    # @api private
    def self.enter_role(role)
      problem = role_problem
      return problem unless problem.empty?

      @role = role
      ""
    end

    # What refuses a second role, "" when none is running: asked before a
    # role changes anything shared (its stop flag, a boot), and again by
    # {.enter_role}.
    # @return [String]
    # @api private
    def self.role_problem
      current = @role
      return "" if current.empty?

      "the #{current} role is already running in this process (one Application runs one role at a time)"
    end

    # Gives the process back when the role has stopped its services.
    # @return [nil]
    # @api private
    def self.leave_role
      @role = ""
      nil
    end

    # @return [String] the role running now ("server", "worker", "feeds"), or ""
    # @api public
    def self.role
      @role
    end
  end
end
