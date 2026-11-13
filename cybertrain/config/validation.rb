# Config's checks: what Application#boot refuses to start with, one method
# per area, and Config#validation_error, which asks them in boot's order
# (docs/design.md D65).
#
# Every method here only reads the Config (and, for time_zone and
# scheduler_tz, the system's zone files): none connects the database,
# creates a file or a directory, or resolves the secret. Those effects are
# cybertrain/config/files.rb's and Application#boot's, after the checks.
#
# The class is reopened here, not split into a validator object that takes
# a Config: each check reads a dozen ivars whose types Spinel already
# knows in this class, and the public names (`config.scheduler_error`)
# stay where applications and tests call them.
module Cybertrain
  class Config
    # The first problem boot would refuse to start with, "" when the
    # configuration is usable. The areas in the order boot has always
    # reported them, after the log settings: the session cookie and CSRF,
    # the request and upload limits, the time zone, the background work, pagination, the
    # proxies, the health check, the feeds, the stream endpoint, the
    # locales, the authentication limits, the mail delivery method, error
    # reporting, the security headers and the encryption keys. Reads only; safe to call from a test or a
    # `--check`-style command with no database and no writable disk.
    # @return [String]
    # @api public
    def validation_error
      problem = log_error
      return problem unless problem.empty?

      problem = session_same_site_error
      return problem unless problem.empty?

      problem = csrf_exempt_prefixes_error
      return problem unless problem.empty?

      problem = max_body_bytes_error
      return problem unless problem.empty?

      problem = upload_limits_error
      return problem unless problem.empty?

      problem = time_zone_error
      return problem unless problem.empty?

      problem = scheduler_error
      return problem unless problem.empty?

      problem = max_page_error
      return problem unless problem.empty?

      problem = trusted_proxies_error
      return problem unless problem.empty?

      problem = health_error
      return problem unless problem.empty?

      problem = feeds_error
      return problem unless problem.empty?

      problem = stream_error
      return problem unless problem.empty?

      problem = i18n_error
      return problem unless problem.empty?

      problem = auth_error
      return problem unless problem.empty?

      problem = mail_delivery_error
      return problem unless problem.empty?

      problem = reporting_error
      return problem unless problem.empty?

      problem = security_error
      return problem unless problem.empty?

      encryption_error
    end

    # The error Application#boot reports for an unknown log_level
    # (CYBERTRAIN_LOG_LEVEL), log_format (CYBERTRAIN_LOG_FORMAT) or entry
    # of log_tags; "" when all are fine.
    # @return [String]
    # @api public
    def log_error
      level = @log_level
      unless level == :debug || level == :info || level == :warn || level == :error || level == :fatal || level == :none
        return "log_level must be :debug, :info, :warn, :error, :fatal or :none (got #{level.inspect})"
      end

      format = @log_format
      return "log_format must be :text or :json (got #{format.inspect})" unless format == :text || format == :json

      tags = @log_tags
      i = 0
      while i < tags.size
        tag = tags[i]
        return "log_tags may hold :request_id and :remote_ip (got #{tag.inspect})" unless tag == :request_id || tag == :remote_ip

        i += 1
      end
      ""
    end

    # The error Application#boot reports when sentry_dsn
    # (CYBERTRAIN_SENTRY_DSN) is set and does not parse ({SentryDsn.problem}:
    # the reason, never the key), or error_sample_rate
    # (CYBERTRAIN_ERROR_SAMPLE_RATE) is not a number from 0.0 to 1.0; ""
    # when both are fine.
    # @return [String]
    # @api public
    def reporting_error
      dsn = @sentry_dsn
      unless dsn.empty?
        why = SentryDsn.problem(dsn)
        return "sentry_dsn must look like https://<public key>@<host>/<project id>: #{why}" unless why.empty?
      end
      text = @error_sample_rate_text
      rate = @error_sample_rate
      in_range = rate >= 0.0 && rate <= 1.0
      unless text.empty?
        return "" if Config.rate_text?(text) && in_range

        return "error_sample_rate must be a number from 0.0 to 1.0 (got #{text.inspect})"
      end
      return "" if in_range

      "error_sample_rate must be a number from 0.0 to 1.0 (got #{rate})"
    end

    # The error Application#boot reports for CYBERTRAIN_FORCE_SSL,
    # CYBERTRAIN_HOSTS, the nonce directives or permissions_policy; "" when
    # all are fine.
    def security_error
      ssl = @force_ssl_text
      unless ssl.empty? || ssl == "1" || ssl == "true" || ssl == "0" || ssl == "false"
        return "CYBERTRAIN_FORCE_SSL must be 1, true, 0, false or empty (got #{ssl.inspect})"
      end

      hosts = @hosts_from_env
      i = 0
      while i < hosts.size
        name = hosts[i].to_s
        return "CYBERTRAIN_HOSTS: #{name.inspect} is not a host name (no scheme, path or wildcard)" unless Config.host_name?(name)

        i += 1
      end
      directives = @content_security_policy_nonce_directives
      i = 0
      while i < directives.size
        directive = directives[i].to_s
        unless ContentSecurityPolicy.directive?(directive)
          return "content_security_policy_nonce_directives: #{directive.inspect} is not a directive"
        end

        i += 1
      end
      policy = @permissions_policy
      return "permissions_policy must not contain CR or LF" if policy.include?("\r") || policy.include?("\n")

      ""
    end

    # The error Application#boot reports (and exits 1 on) when a
    # csrf_exempt_prefixes entry is not a usable prefix: each must start and
    # end with "/" (so "/api" cannot take "/apix" with it) and must not be
    # "/" alone (which would switch the check off for the whole app: that is
    # `c.csrf = false`, said plainly). "" when every entry is fine. A while
    # loop over the typed Array, no block (NOTES rules 32, 45).
    def csrf_exempt_prefixes_error
      prefixes = @csrf_exempt_prefixes
      i = 0
      while i < prefixes.size
        prefix = prefixes[i]
        unless prefix.size >= 2 && prefix.start_with?("/") && prefix.end_with?("/")
          return "csrf_exempt_prefixes entry #{prefix.inspect} must start and end with \"/\" and not be \"/\" alone"
        end
        i += 1
      end
      ""
    end

    # The error Application#boot reports when scheduler_interval,
    # job_poll_interval, job_max_attempts, job_threads,
    # job_heartbeat_interval, job_heartbeat_stale, job_drain_timeout,
    # jobs_page_per_page, cache_prune_interval or scheduler_lease_ttl is
    # below 1, job_heartbeat_stale is not more
    # than job_heartbeat_interval (every live job would look abandoned), or
    # scheduler_lease_ttl is less than twice scheduler_interval (the lease
    # would lapse between two ticks of its holder), or scheduler_tz is not
    # a zone TimeZone can load;
    # "" when all are fine (a sleep of 0 would spin a thread; 0 attempts
    # would fail every job unrun).
    def scheduler_error
      return "scheduler_interval must be at least 1 (got #{@scheduler_interval})" if @scheduler_interval < 1
      return "job_poll_interval must be at least 1 (got #{@job_poll_interval})" if @job_poll_interval < 1
      return "job_max_attempts must be at least 1 (got #{@job_max_attempts})" if @job_max_attempts < 1
      return "job_threads must be at least 1 (got #{@job_threads})" if @job_threads < 1
      return "job_heartbeat_interval must be at least 1 (got #{@job_heartbeat_interval})" if @job_heartbeat_interval < 1
      return "job_heartbeat_stale must be at least 1 (got #{@job_heartbeat_stale})" if @job_heartbeat_stale < 1
      if @job_heartbeat_stale <= @job_heartbeat_interval
        return "job_heartbeat_stale (#{@job_heartbeat_stale}) must be more than job_heartbeat_interval (#{@job_heartbeat_interval})"
      end
      return "job_drain_timeout must be at least 1 (got #{@job_drain_timeout})" if @job_drain_timeout < 1
      return "jobs_page_per_page must be at least 1 (got #{@jobs_page_per_page})" if @jobs_page_per_page < 1
      return "cache_prune_interval must be at least 1 (got #{@cache_prune_interval})" if @cache_prune_interval < 1
      return "scheduler_lease_ttl must be at least 1 (got #{@scheduler_lease_ttl})" if @scheduler_lease_ttl < 1
      if @scheduler_lease_ttl < 2 * @scheduler_interval
        return "scheduler_lease_ttl (#{@scheduler_lease_ttl}) must be at least twice scheduler_interval (#{@scheduler_interval})"
      end
      zone_name = scheduler_tz
      return "scheduler_tz #{zone_name.inspect} is not a known time zone" unless TimeZone.find(zone_name).found?

      ""
    end

    # The error Application#boot reports when time_zone is not a zone
    # TimeZone can load from the system zoneinfo; "" when it is. Asked
    # before scheduler_error, so an unknown time_zone that scheduler_tz
    # follows is reported once, under its own name.
    # @return [String]
    # @api public
    def time_zone_error
      zone_name = @time_zone
      return "time_zone #{zone_name.inspect} is not a known time zone" unless TimeZone.find(zone_name).found?

      ""
    end

    # The error Application#boot reports when i18n_default_locale or an
    # entry of i18n_available_locales is not a locale name (`en`, `pt-BR`),
    # or the default is not in a non-empty i18n_available_locales; "" when
    # all are fine.
    def i18n_error
      default_name = @i18n_default_locale.to_s
      unless Config.locale_name?(default_name)
        return "i18n_default_locale (or CYBERTRAIN_I18N_DEFAULT_LOCALE) must be a locale name such as en or pt-BR (got #{default_name.inspect})"
      end
      list = @i18n_available_locales
      i = 0
      while i < list.size
        entry = list[i].to_s
        unless Config.locale_name?(entry)
          return "i18n_available_locales entries must be locale names such as en or pt-BR (got #{entry.inspect})"
        end
        i += 1
      end
      if !list.empty? && !list.include?(@i18n_default_locale)
        return "i18n_default_locale #{@i18n_default_locale.inspect} is not in i18n_available_locales #{list.inspect}"
      end

      ""
    end

    # The error Application#boot reports when mail_delivery_method is
    # neither :smtp nor :test (from CYBERTRAIN_MAIL_DELIVERY_METHOD or an
    # assignment); "" when it is one of them.
    # @return [String]
    # @api public
    def mail_delivery_error
      delivery = @mail_delivery_method
      return "" if delivery == :smtp || delivery == :test

      "mail_delivery_method must be :smtp or :test (got #{delivery.inspect})"
    end

    # The warning Application#boot logs (and boots on) when
    # mail_delivery_method is :test outside the test environment: every
    # mail is kept in memory and none is sent. "" otherwise.
    # @return [String]
    # @api public
    def mail_delivery_warning
      return "" unless @mail_delivery_method == :test && @env != "test"

      "mail_delivery_method is :test outside the test environment (env #{@env}): " \
        "mail is stored in memory (Mailer.deliveries) and not sent"
    end

    # The error Application#boot reports when an auth_* setting is out of
    # range: auth_lockout_attempts and auth_idle_timeout below 0 (0 is
    # off), auth_lockout_period and auth_remember_for below 1; "" when all
    # are fine.
    def auth_error
      if @auth_lockout_attempts < 0
        return "auth_lockout_attempts must be 0 (off) or more (got #{@auth_lockout_attempts})"
      end
      return "auth_lockout_period must be at least 1 second (got #{@auth_lockout_period})" if @auth_lockout_period < 1
      return "auth_remember_for must be at least 1 second (got #{@auth_remember_for})" if @auth_remember_for < 1
      return "auth_idle_timeout must be 0 (off) or more (got #{@auth_idle_timeout})" if @auth_idle_timeout < 0

      ""
    end

    # The error Application#boot reports when feed_status_interval,
    # feed_restart_limit or feed_restart_window is below 1; "" when all
    # are fine.
    def feeds_error
      return "feed_status_interval must be at least 1 (got #{@feed_status_interval})" if @feed_status_interval < 1
      return "feed_restart_limit must be at least 1 (got #{@feed_restart_limit})" if @feed_restart_limit < 1
      return "feed_restart_window must be at least 1 (got #{@feed_restart_window})" if @feed_restart_window < 1

      ""
    end

    # The error Application#boot reports when health_path is neither ""
    # nor a path starting with "/", health_worker_stale or
    # health_feed_stale is below 1, or the health check is on (a path),
    # health_feeds is on and health_feed_stale is not more than
    # feed_status_interval; "" when all
    # are fine.
    def health_error
      path = @health_path
      unless path.empty? || path.start_with?("/")
        return "health_path must start with \"/\" (or be \"\" to turn the health check off), got #{path.inspect}"
      end
      return "health_worker_stale must be at least 1 (got #{@health_worker_stale})" if @health_worker_stale < 1
      return "health_feed_stale must be at least 1 (got #{@health_feed_stale})" if @health_feed_stale < 1
      # Rows are written every feed_status_interval seconds: a limit no
      # longer than that makes every row stale between two writes. With
      # the health check off (path "") nothing reads the limit.
      if !path.empty? && @health_feeds && @health_feed_stale <= @feed_status_interval
        return "health_feed_stale (#{@health_feed_stale}) must be more than feed_status_interval " \
               "(#{@feed_status_interval}) while health_feeds is on"
      end

      ""
    end

    # The error Application#boot reports when stream_path is neither "" nor
    # a path starting with "/" (or is health_path), or a stream_* number is
    # below its minimum; "" when all are fine.
    def stream_error
      path = @stream_path
      unless path.empty? || path.start_with?("/")
        return "stream_path must start with \"/\" (or be \"\" to turn the stream endpoint off), got #{path.inspect}"
      end
      return "stream_path must differ from health_path (both are #{path.inspect})" if !path.empty? && path == @health_path
      return "stream_poll_ms must be at least 10 (got #{@stream_poll_ms})" if @stream_poll_ms < 10
      return "stream_retention must be at least 1 (got #{@stream_retention})" if @stream_retention < 1
      return "stream_ping_interval must be at least 1 (got #{@stream_ping_interval})" if @stream_ping_interval < 1
      return "stream_max_connections must be at least 1 (got #{@stream_max_connections})" if @stream_max_connections < 1
      return "stream_max_message must be at least 125 (got #{@stream_max_message})" if @stream_max_message < 125
      return "stream_max_backlog must be at least 1 (got #{@stream_max_backlog})" if @stream_max_backlog < 1

      ""
    end

    # The error Application#boot reports when max_page is not an Integer of
    # at least 1, or "" when it is fine.
    def max_page_error
      value = @max_page
      case value
      when Integer
        return "" if value >= 1
      end
      "max_page must be an Integer of at least 1 (got #{value.inspect})"
    end

    # The error Application#boot reports when max_body_bytes is not a
    # positive Integer (nil would make every request with a body a
    # connection error in Server#serve); "" when it is one.
    def max_body_bytes_error
      value = @max_body_bytes
      case value
      when Integer
        return "" if value >= 1
      end
      "max_body_bytes must be an Integer of at least 1 (got #{value.inspect})"
    end

    # The error Application#boot reports (and exits 1 on) when the upload
    # settings are unusable; "" when they are fine. A file larger than the
    # body limit could never arrive, so max_upload_bytes over max_body_bytes
    # is a mistake worth saying (checked only when both are Integers: a bad
    # max_body_bytes has its own message).
    def upload_limits_error
      limit = @max_upload_bytes
      case limit
      when Integer
        return "max_upload_bytes must be an Integer of at least 1 (got #{limit})" if limit < 1

        body_limit = @max_body_bytes
        case body_limit
        when Integer
          return "max_upload_bytes (#{limit}) must not exceed max_body_bytes (#{body_limit})" if limit > body_limit
        end
      else
        return "max_upload_bytes must be an Integer of at least 1 (got #{limit.inspect})"
      end
      parts = @max_multipart_parts
      case parts
      when Integer
        return "max_multipart_parts must be an Integer from 1 to 4096 (got #{parts})" if parts < 1 || parts > 4096
      else
        return "max_multipart_parts must be an Integer from 1 to 4096 (got #{parts.inspect})"
      end
      root = @upload_root
      case root
      when String
        return "upload_root must be a non-empty String" if root.empty?
      else
        return "upload_root must be a non-empty String"
      end
      ""
    end

# The error Application#boot reports (and exits 1 on) when a
# trusted_proxies entry is not an IPv4 or IPv6 address or CIDR
# (IpAddress.parse_network); "" when every entry is one. A while loop,
# no block (NOTES rules 32, 45).
def trusted_proxies_error
  entries = @trusted_proxies
  i = 0
  while i < entries.size
    entry = entries[i].to_s
    if IpAddress.parse_network(entry).empty?
      return "CYBERTRAIN_TRUSTED_PROXIES / trusted_proxies entry #{entry.inspect} is not an IP address or CIDR (e.g. 172.16.0.0/12)"
    end
    i += 1
  end
  ""
end

    # The error Application#boot reports (and exits 1 on) when the
    # encryption keys are unusable; "" when they are fine. A set key must be
    # 64 hex characters, and so must each previous one; an unset key is an
    # error only when a model declares `encrypts`
    # ({Config.encryption_required}). String checks only: the encryption
    # itself (and openssl) is cybertrain/encryptor.rb's.
    def encryption_error
      key = @encryption_key
      hint = "make one with `cybertrain secret --hex`"
      if key.empty?
        return "CYBERTRAIN_ENCRYPTION_KEY is not set; #{hint}" if Config.encryption_required
      elsif !Config.encryption_key_text?(key)
        return "CYBERTRAIN_ENCRYPTION_KEY must be 64 hex characters; #{hint}"
      end
      previous = @encryption_keys_previous
      i = 0
      while i < previous.size
        unless Config.encryption_key_text?(previous[i])
          return "CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS entry #{i + 1} must be 64 hex characters"
        end

        i += 1
      end
      ""
    end

    # The error Application#boot reports (and exits 1 on) when
    # session_same_site is not a value browsers accept; "" when it is one.
    # Case-sensitive, since the value goes into the header as it is; a chain
    # of ==, not include? (spikes/NOTES.md rules 14 and 29).
    def session_same_site_error
      value = @session_same_site
      return "" if value == "Lax" || value == "Strict" || value == "None"

      "CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got \"#{value}\")"
    end
  end
end
