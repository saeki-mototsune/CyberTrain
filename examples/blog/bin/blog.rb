require "cybertrain"
require_relative "../gen/views"      # embedded build: sets CYBERTRAIN_ENV=production by default
require_relative "../config/app"     # so it comes before the config
require_relative "../gen/app"
require_relative "../gen/migrations"

# Operational commands: `./blog NAME ARGS...` runs the block with
# Cybertrain::DB connected (pool of 1) and exits with its value;
# `./blog help` lists them.
#   Cybertrain::Main.command("prune", "delete old comments") do |argv|
#     Cybertrain::DB.with { |c| c.execute("DELETE FROM comments WHERE created_at < date('now', '-30 days')") }
#     0
#   end

# A job, to see which process runs jobs (README, "Deploying with Kamal"):
# `./blog touch 12` enqueues it from its own process, and `./blog worker`
# (or `./blog server`, unless CYBERTRAIN_WORKER=0) runs it and logs the
# article's title.
# A title is visitor-supplied text: a newline in it would start a line of
# its own in the log, so control characters are shown as spaces.
def log_text(text)
  out = +""
  text.each_char { |ch| out << (ch.ord < 32 || ch.ord == 127 ? " " : ch) }
  out
end

Cybertrain::Job.handle("touch") do |payload|
  article = Article.find_by(id: payload.to_i)
  title = article.nil? ? "(no such article)" : log_text(article.title.to_s)
  Cybertrain.logger.info("touch: article #{payload}: #{title}")
end

Cybertrain::Main.command("touch", "enqueue a touch job for an article ID (run by the worker)") do |argv|
  payload = argv.empty? ? "0" : argv[0].to_s
  id = Cybertrain::Job.enqueue("touch", payload)
  puts "enqueued touch job #{id} for article #{payload}"
  0
end

# `./blog user EMAIL [PASSWORD]`, `./blog user admin EMAIL` and
# `./blog user unadmin EMAIL`, and a WARN line at boot while no user exists
# (cybertrain generate authentication --invite-only).
require_relative "../app/commands/user_command"
UserCommand.warn_if_no_user if Cybertrain::Main.server?(ARGV)

exit(Cybertrain::Main.run("blog", ARGV,
                          router: Gen::Routes.build(Cybertrain::Router.new),
                          url_resolver: Gen::Routes.url_resolver,
                          views: Gen::Views::SOURCES))
