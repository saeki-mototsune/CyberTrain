# Cybertrain::JobsPage -- the jobs page `jobs_page "/admin/jobs"` in
# config/routes.rb mounts (the generated CybertrainJobsController calls it),
# and the row actions `./<app> jobs ...` (Job::CLI) shares with it.
require "cybertrain/html"
require "cybertrain/cast"
require "cybertrain/params"
require "cybertrain/config"
require "cybertrain/db"
require "cybertrain/job"
require "cybertrain/views"
require "cybertrain/i18n"
require "cybertrain/template/helpers"

module Cybertrain
  # What the jobs page shows and does. The HTML is built with the tag
  # builder ({Html.tag}), which escapes every value; there is no template
  # file and nothing in the application's `app/views`. It renders inside
  # the application's layout, and its buttons are `button_to` forms with
  # the CSRF token.
  #
  # Every row action is `WHERE id = ? AND state IN ('failed', 'discarded')`,
  # so a row that is queued or that a worker has claimed is left alone, and
  # every value is a bind.
  # @api public
  module JobsPage
    # The states the counts table lists, in this order.
    STATES = ["queued", "running", "done", "failed", "discarded"].freeze

    # The columns a list reads.
    COLUMNS = "id, kind, payload, state, run_at, attempts, last_error, claimed_by, heartbeat_at, created_at, updated_at"

    # The page in the application's layout, for CybertrainJobsController#index:
    # {.index_html} for `?page=N` and {Config#jobs_page_per_page}, inside
    # `Views.layout_name` when that layout exists (the HTML alone otherwise).
    # @param controller [Controller] the controller rendering it
    # @param path [String] the page's path (`"/admin/jobs"`)
    # @return [SafeString]
    # @api public
    def self.page_html(controller, path)
      helpers = Views.helpers_builder.call(controller)
      body = index_html(controller.params.page_number, Cybertrain.config.jobs_page_per_page, path, helpers)
      engine = Views.engine
      frame = Views.layout_name
      return SafeString.of(body) if engine.nil? || frame.empty? || !engine.exists?(frame)

      env = controller.view_env({})
      env["__content"] = SafeString.of(body)
      SafeString.of(engine.render(frame, env, helpers))
    end

    # The page's HTML, its texts the current locale's
    # `cybertrain.jobs_page.*` (`Jobs`, `Failed (%{count})`, ...): the
    # count per state, the queued count and when the next queued job is
    # due, then the `failed`, `discarded` and `running` lists, `per_page`
    # rows each (newest first), and Newer / Older links when a list has
    # more. Failed and discarded rows (kind, arguments,
    # error, attempts, run at, updated) carry retry / discard / delete
    # buttons; running rows show who claimed them and how long ago their
    # process last said so.
    # @param page [Integer] from 1
    # @param per_page [Integer] at least 1
    # @param path [String] the page's path; the buttons post below it
    # @param helpers [Template::Helpers] the request's view helpers, whose
    #   `button_to` adds the CSRF token
    # @return [String] HTML
    # @api public
    def self.index_html(page, per_page, path, helpers)
      per = per_page < 1 ? 1 : per_page
      number = page < 1 ? 1 : page
      now = Clock.now.to_i
      counts = Array.new(0) { 0 }
      STATES.each { |state| counts << Job.state_count(state) }
      parts = Array.new(0) { SafeString.of("") }
      parts << Html.tag("h1", {}, jobs_text("title"))
      parts << counts_table(counts)
      parts << queued_line(counts[0])
      parts << Html.tag("h2", {}, jobs_counted("tabs.failed", counts[3]))
      parts << bulk_buttons(path, helpers) if counts[3] > 0
      parts << finished_list("failed", number, per, path, helpers)
      parts << Html.tag("h2", {}, jobs_counted("tabs.discarded", counts[4]))
      parts << finished_list("discarded", number, per, path, helpers)
      parts << Html.tag("h2", {}, jobs_counted("tabs.running", counts[1]))
      parts << running_list(number, per, now)
      most = counts[1]
      most = counts[3] if counts[3] > most
      most = counts[4] if counts[4] > most
      parts << pagination(number, per, most, path)
      Html.tag("section", { "class" => "cybertrain-jobs" }, Html.safe_join(parts, "\n")).to_s
    end

    # One page of the rows in `state`, newest first, each a Hash of the
    # table's columns (`"id"`, `"kind"`, `"payload"`, `"state"`,
    # `"run_at"`, `"attempts"`, `"last_error"`, `"claimed_by"`,
    # `"heartbeat_at"`, `"created_at"`, `"updated_at"`; times are epoch
    # seconds).
    # @param state [String]
    # @param page [Integer] from 1
    # @param per_page [Integer]
    # @return [Array<Hash{String => Object}>]
    # @api public
    def self.jobs_rows(state, page, per_page)
      Job.ensure_installed
      per = per_page < 1 ? 1 : per_page
      offset = page < 1 ? 0 : (page - 1) * per
      DB.with do |c|
        c.execute("SELECT #{COLUMNS} FROM cybertrain_jobs WHERE state = ? ORDER BY id DESC LIMIT ? OFFSET ?",
                  Cast.binds(state, per, offset))
      end
    end

    # Queues a `failed` or `discarded` job again: `state = 'queued'`,
    # `run_at` now, `attempts = 0` (the retry policy starts afresh),
    # `last_error = ''`, and the {Job.concurrency_key_for} of its kind and
    # payload written in the same UPDATE (a row failed before its kind had
    # a key gets one).
    # @param id [Integer]
    # @return [Boolean] false when there is no such row or it is not
    #   failed or discarded
    # @api public
    def self.retry_job(id)
      Job.ensure_installed
      changed = 0
      DB.with do |c|
        rows = c.execute("SELECT kind, payload FROM cybertrain_jobs WHERE id = ? AND state IN ('failed', 'discarded')", [id])
        changed = requeue(c, id, Cast.str(rows[0]["kind"]), Cast.str(rows[0]["payload"]), Clock.now.to_i) unless rows.empty?
      end
      changed > 0
    end

    # Marks a `failed` job `discarded` (a discarded one stays so).
    # @param id [Integer]
    # @return [Boolean] false when there is no such row or it is not
    #   failed or discarded
    # @api public
    def self.discard_job(id)
      Job.ensure_installed
      changed = 0
      DB.with do |c|
        # A row already discarded keeps its updated_at, so discarding it
        # again does not put off its pruning.
        c.execute("UPDATE cybertrain_jobs SET state = 'discarded', " \
                  "updated_at = CASE WHEN state = 'discarded' THEN updated_at ELSE ? END " \
                  "WHERE id = ? AND state IN ('failed', 'discarded')", Cast.binds(Clock.now.to_i, id))
        changed = c.changes
      end
      changed > 0
    end

    # Deletes a `failed` or `discarded` job.
    # @param id [Integer]
    # @return [Boolean] false when there is no such row or it is not
    #   failed or discarded
    # @api public
    def self.delete_job(id)
      Job.ensure_installed
      changed = 0
      DB.with do |c|
        c.execute("DELETE FROM cybertrain_jobs WHERE id = ? AND state IN ('failed', 'discarded')", [id])
        changed = c.changes
      end
      changed > 0
    end

    # {.retry_job} for every `failed` row, one UPDATE per row (each writes
    # that row's concurrency key), in one transaction.
    # @return [Integer] how many were queued again
    # @api public
    def self.retry_all
      Job.ensure_installed
      now = Clock.now.to_i
      count = 0
      DB.transaction(immediate: true) do |c|
        rows = c.execute("SELECT id, kind, payload FROM cybertrain_jobs WHERE state = 'failed' ORDER BY id")
        rows.each do |row|
          count += requeue(c, Cast.int(row["id"]), Cast.str(row["kind"]), Cast.str(row["payload"]), now)
        end
      end
      count
    end

    # Marks every `failed` row `discarded`.
    # @return [Integer] how many
    # @api public
    def self.discard_all_failed
      Job.ensure_installed
      count = 0
      DB.with do |c|
        c.execute("UPDATE cybertrain_jobs SET state = 'discarded', updated_at = ? WHERE state = 'failed'", [Clock.now.to_i])
        count = c.changes
      end
      count
    end

    # The flash notice of CybertrainJobsController's retry: {.retry_job}
    # on the id the route carried, in the current locale
    # (`cybertrain.jobs_page.notices.retried` / `not_retried`).
    # @param id_text [String, nil] `params[:id]`
    # @return [String]
    def self.retry_notice(id_text)
      id = job_id(id_text)
      return jobs_notice("retried", id) if retry_job(id)

      jobs_notice("not_retried", id)
    end

    # @param id_text [String, nil] `params[:id]`
    # @return [String]
    def self.discard_notice(id_text)
      id = job_id(id_text)
      return jobs_notice("discarded", id) if discard_job(id)

      jobs_notice("not_discarded", id)
    end

    # @param id_text [String, nil] `params[:id]`
    # @return [String]
    def self.delete_notice(id_text)
      id = job_id(id_text)
      return jobs_notice("deleted", id) if delete_job(id)

      jobs_notice("not_deleted", id)
    end

    # @return [String]
    def self.retry_all_notice
      jobs_counted("notices.retried_all", retry_all)
    end

    # @return [String]
    def self.discard_all_failed_notice
      jobs_counted("notices.discarded_all", discard_all_failed)
    end

    # `cybertrain.jobs_page.<key>` in the current locale.
    # @api private
    def self.jobs_text(key)
      I18n.t("cybertrain.jobs_page.#{key}")
    end

    # `cybertrain.jobs_page.<key>` with count: n (`%{count}`).
    # @api private
    def self.jobs_counted(key, n)
      I18n.t("cybertrain.jobs_page.#{key}", { count: n })
    end

    # `cybertrain.jobs_page.notices.<key>` with the job's `%{id}`.
    # @api private
    def self.jobs_notice(key, id)
      I18n.t("cybertrain.jobs_page.notices.#{key}", { id: id.to_s })
    end

    # The id a route carried; 0 (no row) for anything but digits.
    def self.job_id(id_text)
      Params.parse_int(Cast.str(id_text), 0)
    end

    # The requeue UPDATE of retry_job and retry_all, fenced by state; the
    # number of rows changed (0 or 1).
    def self.requeue(conn, id, kind, payload, now)
      key = Job.concurrency_key_for(kind, payload)
      conn.execute("UPDATE cybertrain_jobs SET state = 'queued', run_at = ?, attempts = 0, last_error = '', " \
                   "concurrency_key = ?, updated_at = ? WHERE id = ? AND state IN ('failed', 'discarded')",
                   Cast.binds(now, key, now, id))
      conn.changes
    end

    # "2026-11-09 12:00:00 UTC" for epoch seconds.
    # @api private
    def self.time_text(epoch)
      Time.at(epoch).utc.strftime("%Y-%m-%d %H:%M:%S UTC")
    end

    def self.counts_table(counts)
      rows = Array.new(0) { SafeString.of("") }
      i = 0
      while i < STATES.size
        cells = Html.safe_join([Html.tag("td", {}, jobs_text("states.#{STATES[i]}")), Html.tag("td", {}, counts[i].to_s)])
        rows << Html.tag("tr", {}, cells)
        i += 1
      end
      head = Html.tag("thead", {}, Html.tag("tr", {}, Html.safe_join([Html.tag("th", {}, jobs_text("columns.state")), Html.tag("th", {}, jobs_text("columns.jobs"))])))
      Html.tag("table", { "class" => "jobs-counts" }, Html.safe_join([head, Html.tag("tbody", {}, Html.safe_join(rows))]))
    end

    def self.queued_line(queued)
      line = jobs_text("queued.none")
      if queued > 0
        rows = DB.with { |c| c.execute("SELECT MIN(run_at) AS due FROM cybertrain_jobs WHERE state = 'queued'") }
        due = time_text(Cast.int(rows[0]["due"]))
        line = I18n.t("cybertrain.jobs_page.queued.next", { count: queued, time: due })
      end
      Html.tag("p", { "class" => "jobs-queued" }, line)
    end

    def self.bulk_buttons(path, helpers)
      Html.tag("div", { "class" => "jobs-bulk" },
               Html.safe_join([helpers.button_to_path(jobs_text("buttons.retry_all"), "#{path}/retry_all"),
                               helpers.button_to_path(jobs_text("buttons.discard_all"), "#{path}/discard_all")]))
    end

    # The failed or discarded list, or a line saying it is empty.
    def self.finished_list(state, page, per, path, helpers)
      rows = jobs_rows(state, page, per)
      return Html.tag("p", { "class" => "jobs-empty" }, jobs_text("empty.#{state}")) if rows.empty?

      head = header_row([jobs_text("columns.id"), jobs_text("columns.kind"), jobs_text("columns.arguments"), jobs_text("columns.error"),
                         jobs_text("columns.attempts"), jobs_text("columns.run_at"), jobs_text("columns.updated"), ""])
      lines = Array.new(0) { SafeString.of("") }
      rows.each do |row|
        id = Cast.int(row["id"])
        buttons = Array.new(0) { SafeString.of("") }
        buttons << helpers.button_to_path(jobs_text("buttons.retry"), "#{path}/#{id}/retry")
        buttons << helpers.button_to_path(jobs_text("buttons.discard"), "#{path}/#{id}/discard") if state == "failed"
        buttons << helpers.button_to_path(jobs_text("buttons.delete"), "#{path}/#{id}/delete")
        cells = Array.new(0) { SafeString.of("") }
        cells << Html.tag("td", {}, id.to_s)
        cells << Html.tag("td", {}, Cast.str(row["kind"]))
        cells << Html.tag("td", {}, Cast.str(row["payload"]))
        cells << Html.tag("td", {}, Cast.str(row["last_error"]))
        cells << Html.tag("td", {}, Cast.int(row["attempts"]).to_s)
        cells << Html.tag("td", {}, time_text(Cast.int(row["run_at"])))
        cells << Html.tag("td", {}, time_text(Cast.int(row["updated_at"])))
        cells << Html.tag("td", {}, Html.safe_join(buttons))
        lines << Html.tag("tr", {}, Html.safe_join(cells))
      end
      Html.tag("table", { "class" => "jobs-#{state}" }, Html.safe_join([head, Html.tag("tbody", {}, Html.safe_join(lines, "\n"))]))
    end

    def self.running_list(page, per, now)
      rows = jobs_rows("running", page, per)
      return Html.tag("p", { "class" => "jobs-empty" }, jobs_text("empty.running")) if rows.empty?

      head = header_row([jobs_text("columns.id"), jobs_text("columns.kind"), jobs_text("columns.claimed_by"), jobs_text("columns.heartbeat")])
      lines = Array.new(0) { SafeString.of("") }
      rows.each do |row|
        beat = row["heartbeat_at"]
        age = jobs_text("heartbeat.none")
        age = I18n.t("cybertrain.jobs_page.heartbeat.ago", { seconds: (now - Cast.int(beat)).to_s }) unless beat.nil?
        cells = Array.new(0) { SafeString.of("") }
        cells << Html.tag("td", {}, Cast.int(row["id"]).to_s)
        cells << Html.tag("td", {}, Cast.str(row["kind"]))
        cells << Html.tag("td", {}, Cast.str(row["claimed_by"]))
        cells << Html.tag("td", {}, age)
        lines << Html.tag("tr", {}, Html.safe_join(cells))
      end
      Html.tag("table", { "class" => "jobs-running" }, Html.safe_join([head, Html.tag("tbody", {}, Html.safe_join(lines, "\n"))]))
    end

    def self.header_row(titles)
      cells = Array.new(0) { SafeString.of("") }
      titles.each { |t| cells << Html.tag("th", {}, t) }
      Html.tag("thead", {}, Html.tag("tr", {}, Html.safe_join(cells)))
    end

    # Newer / Older links (the pager's `cybertrain.pager.newer` / `older`)
    # when the longest list has rows before or after this page; nothing
    # otherwise.
    def self.pagination(page, per, most, path)
      links = Array.new(0) { SafeString.of("") }
      links << Html.tag("a", { "href" => "#{path}?page=#{page - 1}" }, I18n.t("cybertrain.pager.newer")) if page > 1
      links << Html.tag("a", { "href" => "#{path}?page=#{page + 1}" }, I18n.t("cybertrain.pager.older")) if page * per < most
      return SafeString.of("") if links.empty?

      Html.tag("nav", { "class" => "pagination" }, Html.safe_join(links, " "))
    end
  end
end
