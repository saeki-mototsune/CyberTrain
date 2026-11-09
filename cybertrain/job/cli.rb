require "cybertrain/cast"
require "cybertrain/params"
require "cybertrain/job"
require "cybertrain/jobs_page"

module Cybertrain
  module Job
    # Cybertrain::Job::CLI -- `./<app> jobs ...` (Cybertrain::Main), on the
    # database Main connected; it starts no thread:
    #
    #   jobs list [STATE]       a table of the rows in STATE (failed by default), newest first
    #   jobs retry ID | --all   queue a failed or discarded job again (--all: every failed one)
    #   jobs discard ID         mark a failed job discarded
    #   jobs delete ID          delete a failed or discarded job
    #   jobs prune [--before DAYS]  delete failed and discarded jobs older than DAYS (7)
    #
    # The row actions are {JobsPage}'s, so they too touch only failed and
    # discarded rows.
    module CLI
      USAGE = "usage: jobs (list [queued|running|done|failed|discarded]|retry ID|retry --all|discard ID|delete ID|prune [--before DAYS])"

      # The longest error excerpt `list` prints, in characters.
      ERROR_EXCERPT = 60

      # @param argv [Array<String>] the words after `jobs`
      # @return [Integer] the exit status: 0, or 1 for a usage error, a row
      #   the action cannot touch, or an error from the database
      def self.run(argv)
        return usage if argv.empty?

        begin
          dispatch(argv)
        rescue StandardError => e
          puts "jobs #{argv[0]} failed: #{e.message}"
          1
        end
      end

      def self.dispatch(argv)
        case argv[0]
        when "list"
          return usage if argv.size > 2

          state = argv.size == 2 ? argv[1] : "failed"
          return usage unless JobsPage::STATES.include?(state)

          list(state)
        when "retry"
          return usage unless argv.size == 2
          return retry_all if argv[1] == "--all"

          row_action("retry", argv[1])
        when "discard", "delete"
          return usage unless argv.size == 2

          row_action(argv[0], argv[1])
        when "prune"
          days = prune_days(argv)
          return usage if days < 0

          prune(days)
        else
          puts "unknown command: jobs #{argv[0]}"
          usage
        end
      end

      def self.usage
        puts USAGE
        1
      end

      # Every row in state as a table: id, kind, state, attempts, run_at
      # (UTC) and the first line of the error, cut to ERROR_EXCERPT.
      def self.list(state)
        rows = JobsPage.jobs_rows(state, 1, Job.state_count(state))
        if rows.empty?
          puts "no #{state} jobs"
          return 0
        end
        table = Array.new(0) { Array.new(0) { "" } }
        table << ["ID", "KIND", "STATE", "ATTEMPTS", "RUN AT", "ERROR"]
        rows.each do |row|
          table << [Cast.int(row["id"]).to_s, Cast.str(row["kind"]), Cast.str(row["state"]),
                    Cast.int(row["attempts"]).to_s, JobsPage.time_text(Cast.int(row["run_at"])),
                    error_excerpt(Cast.str(row["last_error"]))]
        end
        widths = Array.new(0) { 0 }
        table[0].each { |cell| widths << cell.size }
        table.each do |line|
          line.each_with_index { |cell, i| widths[i] = cell.size if cell.size > widths[i] }
        end
        table.each do |line|
          text = +""
          line.each_with_index do |cell, i|
            text << "  " if i > 0
            text << (i == line.size - 1 ? cell : cell.ljust(widths[i]))
          end
          puts text.rstrip
        end
        0
      end

      def self.error_excerpt(text)
        first = text.split("\n", 2)
        line = first.empty? ? "" : first[0]
        return line if line.size <= ERROR_EXCERPT

        "#{line[0, ERROR_EXCERPT - 3]}..."
      end

      # retry, discard or delete one row; 1 when ID is not a number or the
      # row is not failed or discarded.
      def self.row_action(action, text)
        id = row_id(text)
        return usage if id < 1

        done = case action
               when "retry" then JobsPage.retry_job(id)
               when "discard" then JobsPage.discard_job(id)
               else JobsPage.delete_job(id)
               end
        unless done
          puts "job #{id}: no failed or discarded job with this id"
          return 1
        end
        past = case action
               when "retry" then "queued again"
               when "discard" then "discarded"
               else "deleted"
               end
        puts "job #{id} #{past}"
        0
      end

      def self.retry_all
        puts "#{JobsPage.retry_all} failed job(s) queued again"
        0
      end

      # The id in text; 0 when it is not 1 to 18 digits.
      def self.row_id(text)
        return 0 unless Cast.digits?(text) && !text.empty?

        Params.parse_int(text, 0)
      end

      # The most DAYS `prune --before` takes (about a thousand years).
      MAX_PRUNE_DAYS = 365_000

      # 7 without `--before`; DAYS (digits, at most MAX_PRUNE_DAYS) with
      # it; -1 for anything else.
      def self.prune_days(argv)
        return 7 if argv.size == 1
        return -1 unless argv.size == 3 && argv[1] == "--before"
        return -1 unless Cast.digits?(argv[2]) && !argv[2].empty?

        days = Params.parse_int(argv[2], -1)
        days > MAX_PRUNE_DAYS ? -1 : days
      end

      def self.prune(days)
        count = Job.prune_finished(Time.now.to_i - days * 86_400)
        puts "pruned #{count} failed or discarded job(s) last updated more than #{days} day(s) ago"
        0
      end
    end
  end
end
