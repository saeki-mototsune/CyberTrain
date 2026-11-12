require "tmpdir"
require "cybertrain/cli"
require "cybertrain/test"

# `cybertrain generate authentication` run again over an application an
# older generator wrote (spec §14, D19): test/fixtures/auth_04_app, a
# sign-up application v0.4.1 generated (its SOURCE says how), copied to a
# temporary directory per test. The missing files and the add-columns
# migration are written; each file the generator writes whole that exists
# with other content is left alone and its diff printed (CLI::LineDiff,
# which `patch -p1` applies), or overwritten with --force; 0.4's
# authentication block in ApplicationController becomes `include
# Authentication`. What the upgraded application does once built is
# `script/auth-e2e upgrade04`'s.
ROOT = Dir.pwd
FIXTURE = "#{ROOT}/test/fixtures/auth_04_app"
EXPECTED_OUTPUT = "#{ROOT}/test/fixtures/auth_04_app.upgrade.diff"
TMP = Dir.mktmpdir("cybertrain-cli-authentication-upgrade")
Dir.chdir(TMP)

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

ENV["CYBERTRAIN_TIMESTAMP"] = "20260925120000"

# A fresh copy of the 0.4 application at TMP/name.
def copy_fixture(name)
  raise "cp failed" unless system("cp", "-R", FIXTURE, "#{TMP}/#{name}")

  name
end

def read(path)
  File.read(path)
end

# `cybertrain generate authentication ARGS` run in TMP/name by CRuby, as a
# user runs it; its output (stdout and stderr) in TMP/name.out.
def run_cli(name, args)
  out = "#{TMP}/#{name}.out"
  script = "cd \"$1\" && CYBERTRAIN_TIMESTAMP=20260925120000 ruby -I\"$2\" \"$2/exe/cybertrain\" generate authentication #{args} > \"$3\" 2>&1"
  ok = system("sh", "-c", script, "sh", "#{TMP}/#{name}", ROOT, out)
  raise "generate authentication #{args} failed in #{name}: #{read(out)}" unless ok

  read(out)
end

# `patch -p1` of diff_text in TMP/name: whether it applied.
def patch_in(name, diff_text)
  File.write("#{TMP}/#{name}.patch", diff_text)
  system("sh", "-c", "cd \"$1\" && patch -s -p1 < \"$2\"", "sh", "#{TMP}/#{name}", "#{TMP}/#{name}.patch")
end

# The lines of a diff that begin with mark ("-" or "+"), the mark taken
# off; the --- and +++ lines left out.
def diff_side(diff, mark)
  out = +""
  diff.each_line do |line|
    next if line.start_with?("--- a/") || line.start_with?("+++ b/")

    out << line[1, line.size - 1].to_s if line.start_with?(mark)
  end
  out
end

# The 0.4 application's files the generator writes whole: each is left
# alone with a diff, or overwritten with --force.
CHANGED = [
  "app/models/user.rb",
  "app/models/session.rb",
  "app/controllers/sessions_controller.rb",
  "app/controllers/registrations_controller.rb",
  "app/views/sessions/new.html.erb",
  "app/views/sessions/_nav.html.erb",
  "app/views/registrations/new.html.erb",
  "test/support/app_test.rb",
  "test/authentication.rb"
]

# What 0.4 did not write.
MISSING = [
  "db/migrate/20260925120002_add_authentication_columns.rb",
  "app/controllers/concerns/authentication.rb",
  "app/controllers/passwords_controller.rb",
  "app/controllers/accounts_controller.rb",
  "app/mailers/passwords_mailer.rb",
  "app/commands/user_command.rb",
  "app/views/passwords/new.html.erb",
  "app/views/passwords/edit.html.erb",
  "app/views/mail/_password_reset.html.erb",
  "app/views/accounts/edit.html.erb",
  "test/support/authentication_helpers.rb",
  "test/admin.rb",
  "test/remember_me.rb",
  "test/lockout.rb",
  "test/passwords.rb",
  "test/accounts.rb"
]

ADD_COLUMNS = <<~RUBY
  # The columns `cybertrain generate authentication` reads that the
  # migrations before this one did not create.
  class AddAuthenticationColumns < Cybertrain::Migration::Base
    def change
      add_column "users", "admin", :boolean, null: false, default: "false"
      add_column "users", "failed_attempts", :integer, null: false, default: "0"
      add_column "users", "locked_until", :datetime
      add_column "sessions", "remember", :boolean, null: false, default: "false"
      add_column "sessions", "last_active_at", :datetime
    end
  end
RUBY

# The application `cybertrain new` and today's generator write, to compare
# an upgraded one with: TMP/fresh/shop (named shop, as the fixture is).
Dir.mkdir("fresh")
Dir.chdir("fresh") { Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }") }
Cybertrain::CLI::Authentication.generate_with_result("fresh/shop")

UPGRADED = copy_fixture("upgraded")
UPGRADE = Cybertrain::CLI::Authentication.generate_with_result(UPGRADED)

# How many `@@` lines a diff has.
def hunks(diff)
  n = 0
  diff.each_line { |line| n += 1 if line.start_with?("@@ ") }
  n
end

def manual_for(result, path)
  found = ""
  result.manual.each { |entry| found = entry if entry.start_with?("manual  #{path}: ") }
  found
end

test "the fixture holds 0.4's block exactly as LEGACY_APPLICATION_CONTROLLER_BLOCKS has it" do
  legacy = Cybertrain::CLI::Authentication::LEGACY_APPLICATION_CONTROLLER_BLOCKS
  assert_equal 1, legacy.size
  block = Cybertrain::CLI::Authentication.indent(legacy[0])
  controller = read("#{FIXTURE}/app/controllers/application_controller.rb")
  assert controller.start_with?("class ApplicationController < Cybertrain::Controller\n#{block}  rescue_from ")
  assert block.start_with?(Cybertrain::CLI::Authentication::LEGACY_BLOCK_START)
  assert block.end_with?("#{Cybertrain::CLI::Authentication::LEGACY_BLOCK_END}\n")
  assert_includes block, "  def start_new_session_for(user)\n"
end

test "a re-run on a 0.4 application writes the missing files" do
  assert_equal MISSING, UPGRADE.created
  assert_equal [], UPGRADE.forced
  MISSING.each { |f| assert_equal read("fresh/shop/#{f}"), read("upgraded/#{f}") unless f.start_with?("db/") }
  assert_equal ADD_COLUMNS, read("upgraded/db/migrate/20260925120002_add_authentication_columns.rb")
  # The migrations that have run are not touched.
  assert_equal read("#{FIXTURE}/db/migrate/20260925120000_create_users.rb"), read("upgraded/db/migrate/20260925120000_create_users.rb")
  assert_equal read("#{FIXTURE}/db/migrate/20260925120001_create_sessions.rb"), read("upgraded/db/migrate/20260925120001_create_sessions.rb")
  # The marker edits are made: the new routes, the user command, base_url.
  routes = read("upgraded/config/routes.rb")
  assert_includes routes, "  resource :session, only: [:new, :create, :destroy]\n  resources :passwords, param: :token, only: [:new, :create, :edit, :update]\n  resource :account, only: [:edit, :update, :destroy]\n"
  assert_includes read("upgraded/bin/shop.rb"), "require_relative \"../app/commands/user_command\"\n"
  assert_includes read("upgraded/config/app.rb"), "setting_string :base_url"
end

test "it prints a diff for each changed file and leaves them alone" do
  copy_fixture("printed")
  output = run_cli("printed", "")
  assert_equal read(EXPECTED_OUTPUT), output
  (CHANGED + ["app/controllers/application_controller.rb", "app/views/layouts/application.html.erb"]).each do |f|
    assert_equal read("#{FIXTURE}/#{f}"), read("printed/#{f}")
  end
  # One heading per diff, in the order the files are written.
  headings = Array.new(0) { "" }
  output.each_line { |line| headings << line.split(":")[0].to_s.delete_prefix("manual  ") if line.start_with?("manual  ") && line.include?(": apply") }
  assert_equal CHANGED + ["app/controllers/application_controller.rb", "config/routes.rb"], headings
  assert_equal headings, UPGRADE.manual.map { |entry| entry.lines[0].split(":")[0].to_s.delete_prefix("manual  ") }
  # The closing lines: what to do, and that the app may not build before
  # (D19 leaves the existing files as they are; review M1).
  assert output.end_with?("\nnext: apply the diffs above, or re-run with --force for files you never edited\n" \
                          "  # the app may not build until these diffs are applied: the files written now need them\n")
  # The whole output, given to patch -p1, makes the 0.4 application the one
  # today's generator writes.
  assert patch_in("printed", output)
  (CHANGED + MISSING).each { |f| assert_equal read("fresh/shop/#{f}"), read("printed/#{f}") unless f.start_with?("db/") }
  ["app/controllers/application_controller.rb", "config/routes.rb"].each { |f| assert_equal read("fresh/shop/#{f}"), read("printed/#{f}") }
  # Run again, nothing is left to change.
  again = Cybertrain::CLI::Authentication.generate_with_result("printed")
  assert_equal [], again.created
  assert_equal [], again.manual
end

test "the application_controller diff removes 0.4's block and includes Authentication" do
  diff = manual_for(UPGRADE, "app/controllers/application_controller.rb")
  block = Cybertrain::CLI::Authentication.indent(Cybertrain::CLI::Authentication::LEGACY_APPLICATION_CONTROLLER_BLOCKS[0])
  assert diff.start_with?("manual  app/controllers/application_controller.rb: apply this diff by hand, or re-run with --force to overwrite the file\n" \
                          "--- a/app/controllers/application_controller.rb\n" \
                          "+++ b/app/controllers/application_controller.rb\n" \
                          "@@ -1,95 +1,5 @@\n" \
                          " class ApplicationController < Cybertrain::Controller\n")
  # Every line of the block goes but its last blank one (which the include
  # keeps), and only the include comes in.
  assert_equal block.delete_suffix("\n"), diff_side(diff, "-")
  assert_equal "  include Authentication\n", diff_side(diff, "+")
  assert_includes diff, "+  include Authentication\n \n   rescue_from Cybertrain::RecordNotFound"
  # The jobs page needs require_admin, which comes with the include: its
  # route is a diff too, applied together.
  routes = manual_for(UPGRADE, "config/routes.rb")
  assert_equal "manual  config/routes.rb: apply this diff by hand with application_controller.rb's (require_admin comes with include Authentication)\n" \
               "--- a/config/routes.rb\n" \
               "+++ b/config/routes.rb\n" \
               "@@ -4,4 +4,5 @@\n" \
               "   resource :account, only: [:edit, :update, :destroy]\n" \
               "   get \"/sign_up\", to: \"registrations#new\", as: \"sign_up\"\n" \
               "   post \"/sign_up\", to: \"registrations#create\"\n" \
               "+  jobs_page \"/admin/jobs\", before_action: :require_admin, skip_before_action: :require_authentication\n" \
               " end\n", routes
  # The other diffs Tasks 11 to 14 need: the remember-me box, the nav's
  # Account link.
  assert_includes manual_for(UPGRADE, "app/views/sessions/new.html.erb"), "+    <%= check_box_tag :remember_me %>\n"
  assert_includes manual_for(UPGRADE, "app/views/sessions/_nav.html.erb"), "+    <%= link_to t(\".account\"), edit_account_path %>\n"
  # Applied, the controller is the include and 0.4's other lines.
  copy_fixture("applied")
  assert patch_in("applied", diff)
  assert_equal "class ApplicationController < Cybertrain::Controller\n  include Authentication\n\n#{read("#{FIXTURE}/app/controllers/application_controller.rb").delete_prefix("class ApplicationController < Cybertrain::Controller\n#{block}")}",
               read("applied/app/controllers/application_controller.rb")
end

test "--force overwrites the generator's files and replaces an exact 0.4 block" do
  copy_fixture("forced")
  result = Cybertrain::CLI::Authentication.generate_with_result("forced", false, false, true)
  assert_equal MISSING, result.created
  assert_equal CHANGED + ["app/controllers/application_controller.rb"], result.forced
  assert_equal [], result.manual
  (CHANGED + MISSING).each { |f| assert_equal read("fresh/shop/#{f}"), read("forced/#{f}") unless f.start_with?("db/") }
  # The include in place of the block, and the jobs page drawn behind it.
  assert_equal read("fresh/shop/app/controllers/application_controller.rb"), read("forced/app/controllers/application_controller.rb")
  assert_equal read("fresh/shop/config/routes.rb"), read("forced/config/routes.rb")
  # --force never rewrites a migration.
  assert_equal read("#{FIXTURE}/db/migrate/20260925120000_create_users.rb"), read("forced/db/migrate/20260925120000_create_users.rb")
  # Through the command line too, with the forced files named.
  copy_fixture("forced_cli")
  output = run_cli("forced_cli", "--force")
  assert_includes output, "force  app/models/user.rb\n"
  assert_includes output, "force  app/controllers/application_controller.rb (0.4's authentication block replaced by include Authentication)\n"
  assert_includes output, "route jobs_page \"/admin/jobs\", before_action: :require_admin, skip_before_action: :require_authentication\n"
  assert output.index("manual  ").nil?
  assert output.index("next: apply the diffs above").nil?
end

test "--force leaves an edited application_controller.rb and prints its diff" do
  copy_fixture("edited")
  path = "edited/app/controllers/application_controller.rb"
  edited = read(path).sub("    redirect_to new_session_path, status: :see_other\n", "    redirect_to \"/sign_in\", status: :see_other\n")
  refute read(path) == edited
  File.write(path, edited)
  result = Cybertrain::CLI::Authentication.generate_with_result("edited", false, false, true)
  assert_equal edited, read(path)
  assert_equal CHANGED, result.forced
  assert_equal 2, result.manual.size
  diff = manual_for(result, "app/controllers/application_controller.rb")
  assert diff.start_with?("manual  app/controllers/application_controller.rb: apply this diff by hand (0.4's authentication block was edited, so --force leaves it alone)\n--- a/")
  assert_includes diff, "-    redirect_to \"/sign_in\", status: :see_other\n"
  assert_equal "  include Authentication\n", diff_side(diff, "+")
  # The jobs page waits for the include.
  assert read("edited/config/routes.rb").index("jobs_page").nil?
  assert manual_for(result, "config/routes.rb").start_with?("manual  config/routes.rb: ")
  # Both applied, it is today's.
  assert patch_in("edited", result.manual.join)
  assert_equal read("fresh/shop/app/controllers/application_controller.rb"), read(path)
  assert_equal read("fresh/shop/config/routes.rb"), read("edited/config/routes.rb")
end

test "--confirmable over a 0.4 application adds all seven columns and confirms the users there" do
  copy_fixture("confirm04")
  result = Cybertrain::CLI::Authentication.generate_with_result("confirm04", false, true)
  assert_equal <<~RUBY, read("confirm04/db/migrate/20260925120002_add_authentication_columns.rb")
    # The columns `cybertrain generate authentication` reads that the
    # migrations before this one did not create.
    class AddAuthenticationColumns < Cybertrain::Migration::Base
      def change
        add_column "users", "admin", :boolean, null: false, default: "false"
        add_column "users", "failed_attempts", :integer, null: false, default: "0"
        add_column "users", "locked_until", :datetime
        add_column "sessions", "remember", :boolean, null: false, default: "false"
        add_column "sessions", "last_active_at", :datetime
        add_column "users", "confirmed_at", :datetime
        add_column "users", "unconfirmed_email", :string
        # The users already here signed up when nobody was asked to
        # confirm an address: they count as confirmed since they were
        # created, or none of them could sign in again.
        reversible do |dir|
          dir.up { execute "UPDATE users SET confirmed_at = COALESCE(created_at, strftime('%Y-%m-%d %H:%M:%S.000000', 'now')) WHERE confirmed_at IS NULL" }
        end
      end
    end
  RUBY
  # Until the sessions and registrations diffs are applied, they do not
  # ask for a confirmation (the concern still refuses the session): their
  # headings say so first.
  [["app/controllers/sessions_controller.rb", "until this diff is applied, an unconfirmed account's right password is refused without its message (the concern refuses it)"],
   ["app/controllers/registrations_controller.rb", "until this diff is applied, a sign-up is mailed no confirmation link (the concern signs it in no more)"]].each do |pair|
    f = pair[0]
    assert manual_for(result, f).start_with?("manual  #{f}: apply this diff by hand, or re-run with --force to overwrite the file\n" \
                                             "IMPORTANT: #{pair[1]}\n--- a/#{f}\n")
  end
  assert_includes manual_for(result, "app/controllers/sessions_controller.rb"), "user.confirmed?"
  assert_includes read("confirm04/config/routes.rb"), "resources :confirmations, param: :token, only: [:new, :create, :show]\n"
  assert_includes result.created, "app/controllers/confirmations_controller.rb"
  assert_includes result.created, "test/confirmations.rb"
end

test "the add-columns migration is decided per missing column (F19)" do
  # Today's application without --confirmable, run again with it: only the
  # two columns --confirmable reads.
  Cybertrain::CLI::NewApp.create("plain", "{ path = \"../cybertrain\" }")
  Cybertrain::CLI::Authentication.generate_with_result("plain")
  result = Cybertrain::CLI::Authentication.generate_with_result("plain", false, true)
  assert_includes result.created, "db/migrate/20260925120002_add_authentication_columns.rb"
  migration = read("plain/db/migrate/20260925120002_add_authentication_columns.rb")
  assert_includes migration, "    add_column \"users\", \"confirmed_at\", :datetime\n    add_column \"users\", \"unconfirmed_email\", :string\n    # The users"
  assert migration.index("\"admin\"").nil?
  assert migration.index("\"remember\"").nil?
  # Again: nothing is missing now, so no migration.
  again = Cybertrain::CLI::Authentication.generate_with_result("plain", false, true)
  assert_equal [], again.created
  # Without --confirmable, a 0.4 application whose admin column a migration
  # of its own added gets only the other four; a later one finds a name
  # of its own.
  copy_fixture("partial")
  File.write("partial/db/migrate/20260930000000_add_admin_to_users.rb",
             "class AddAdminToUsers < Cybertrain::Migration::Base\n  def change\n    add_column \"users\", \"admin\", :boolean, null: false, default: \"false\"\n  end\nend\n")
  File.write("partial/db/migrate/20260930000001_add_authentication_columns.rb",
             "class AddAuthenticationColumns < Cybertrain::Migration::Base\n  def change\n    add_column :sessions, :remember, :boolean\n  end\nend\n")
  partial = Cybertrain::CLI::Authentication.generate_with_result("partial")
  assert_equal "db/migrate/20260930000002_add_authentication_columns_2.rb", partial.created[0]
  assert_equal "# The columns `cybertrain generate authentication` reads that the\n" \
               "# migrations before this one did not create.\n" \
               "class AddAuthenticationColumns2 < Cybertrain::Migration::Base\n" \
               "  def change\n" \
               "    add_column \"users\", \"failed_attempts\", :integer, null: false, default: \"0\"\n" \
               "    add_column \"users\", \"locked_until\", :datetime\n" \
               "    add_column \"sessions\", \"last_active_at\", :datetime\n" \
               "  end\n" \
               "end\n", read("partial/db/migrate/20260930000002_add_authentication_columns_2.rb")
  # db/schema.rb counts as well as the migrations.
  assert_equal true, Cybertrain::CLI::Authentication.declares_column?("Cybertrain::Schema.define(version: \"1\") do |s|\n  s.create_table \"users\" do |t|\n    t.datetime \"locked_until\"\n  end\nend\n", "users", "locked_until")
  assert_equal false, Cybertrain::CLI::Authentication.declares_column?("  s.create_table \"sessions\" do |t|\n    t.datetime \"locked_until\"\n  end\n", "users", "locked_until")
end

test "declares_column? names a column only where it ends (review M3)" do
  auth = Cybertrain::CLI::Authentication
  # The reviewer's five: each names another column, another table, or a
  # comment.
  assert_equal false, auth.declares_column?("    add_column :users, :admin_notes, :string\n", "users", "admin")
  assert_equal false, auth.declares_column?("    add_column :sessions, :remember_token, :string\n", "sessions", "remember")
  assert_equal false, auth.declares_column?("    create_table :users_archive do |t|\n      t.boolean :admin\n    end\n", "users", "admin")
  assert_equal false, auth.declares_column?("    create_table \"users\" do |t|\n      # t.datetime \"confirmed_at\"\n    end\n", "users", "confirmed_at")
  assert_equal false, auth.declares_column?("    create_table \"users\" do |t|\n      t.string \"email\", comment: \"admin\"\n    end\n", "users", "admin")
  # A commented add_column is not one either.
  assert_equal false, auth.declares_column?("    # add_column \"users\", \"admin\", :boolean\n", "users", "admin")
  # What does name it: strings or symbols, in create_table, the schema
  # dump or add_column, with options after it or none.
  assert_equal true, auth.declares_column?("    create_table \"users\" do |t|\n      t.boolean \"admin\", null: false\n    end\n", "users", "admin")
  assert_equal true, auth.declares_column?("    create_table :users do |t|\n      t.boolean :admin\n    end\n", "users", "admin")
  assert_equal true, auth.declares_column?("  s.create_table \"users\" do |t|\n    t.datetime \"locked_until\"\n  end\n", "users", "locked_until")
  assert_equal true, auth.declares_column?("    add_column :users, :admin, :boolean\n", "users", "admin")
  assert_equal true, auth.declares_column?("    add_column \"sessions\", \"remember\", :boolean, null: false, default: \"false\"\n", "sessions", "remember")
  assert_equal true, auth.declares_column?("    add_column \"users\", :admin\n", "users", "admin")
  assert_equal true, auth.declares_column?("    add_column :users, \"admin\", :boolean\n", "users", "admin")
end

test "a block that is there twice, or has lost its end line, is left alone (review M2, M6)" do
  block = Cybertrain::CLI::Authentication.indent(Cybertrain::CLI::Authentication::LEGACY_APPLICATION_CONTROLLER_BLOCKS[0])
  copy_fixture("twice")
  path = "twice/app/controllers/application_controller.rb"
  twice = read(path).sub(block, "#{block}#{block}")
  File.write(path, twice)
  result = Cybertrain::CLI::Authentication.generate_with_result("twice", false, false, true)
  assert_equal twice, read(path)
  refute result.forced.include?("app/controllers/application_controller.rb")
  assert_equal "", manual_for(result, "app/controllers/application_controller.rb")
  copy_fixture("endless")
  path = "endless/app/controllers/application_controller.rb"
  endless = read(path).sub(Cybertrain::CLI::Authentication::LEGACY_BLOCK_END, "")
  refute endless == read(path)
  File.write(path, endless)
  result = Cybertrain::CLI::Authentication.generate_with_result("endless", false, false, true)
  assert_equal endless, read(path)
  refute result.forced.include?("app/controllers/application_controller.rb")
  assert_equal "", manual_for(result, "app/controllers/application_controller.rb")
  # Through the command line, each says why.
  copy_fixture("twice_cli")
  File.write("twice_cli/app/controllers/application_controller.rb", twice)
  assert_includes run_cli("twice_cli", "--force"), "skip app/controllers/application_controller.rb (0.4's authentication block is there more than once): " \
                                                   "replace each with one `include Authentication` (app/controllers/concerns/authentication.rb)\n"
  copy_fixture("endless_cli")
  File.write("endless_cli/app/controllers/application_controller.rb", endless)
  assert_includes run_cli("endless_cli", "--force"), "skip app/controllers/application_controller.rb (0.4's authentication block has no end line): " \
                                                     "replace that code with `include Authentication` (app/controllers/concerns/authentication.rb)\n"
end

test "the jobs page's line goes inside the draw block, or a skip line says why not (review M4)" do
  auth = Cybertrain::CLI::Authentication
  line = auth::JOBS_PAGE_LINE
  # The draw block's own end, at the draw line's indentation: not a later
  # top-level end, and inside a module too.
  assert_equal ["Cybertrain::Routes.draw do\n  get \"/\", to: \"home#index\"\n  #{line}\nend\n\nmodule Later\nend\n", ""],
               auth.jobs_page_plan("Cybertrain::Routes.draw do\n  get \"/\", to: \"home#index\"\nend\n\nmodule Later\nend\n", true)
  assert_equal ["module App\n  Cybertrain::Routes.draw do\n    #{line}\n  end\nend\n", ""],
               auth.jobs_page_plan("module App\n  Cybertrain::Routes.draw do\n  end\nend\n", true)
  # A last end with no newline after it.
  assert_equal ["Cybertrain::Routes.draw do\n  #{line}\nend", ""], auth.jobs_page_plan("Cybertrain::Routes.draw do\nend", true)
  # The reasons.
  assert_equal ["", "drawn"], auth.jobs_page_plan("Cybertrain::Routes.draw do\n  #{line}\nend\n", true)
  assert_equal ["", "it has a jobs_page line of its own"], auth.jobs_page_plan("Cybertrain::Routes.draw do\n  # jobs_page \"/jobs\"\nend\n", true)
  assert_equal ["", "no `end` of the Cybertrain::Routes.draw block at its indentation"],
               auth.jobs_page_plan("Cybertrain::Routes.draw do\n  get \"/\", to: \"home#index\" end\n", true)
  assert_equal ["", "no `# jobs_page \"/admin/jobs\", before_action: :require_admin` comment to draw"],
               auth.jobs_page_plan("Cybertrain::Routes.draw do\nend\n", false)
  # Through generate: a 0.4 app whose routes mention jobs_page already, one
  # whose draw block has no end of its own line, and a re-run after only
  # the application_controller diff was applied (no comment to draw).
  skip = ": to show the jobs page to admins, add `#{line}` inside Cybertrain::Routes.draw\n"
  copy_fixture("mentioned")
  File.write("mentioned/config/routes.rb", "#{read("mentioned/config/routes.rb").delete_suffix("end\n")}  # jobs_page later\nend\n")
  assert_includes run_cli("mentioned", ""), "skip config/routes.rb (it has a jobs_page line of its own)#{skip}"
  copy_fixture("shapeless")
  File.write("shapeless/config/routes.rb", "#{read("shapeless/config/routes.rb").delete_suffix("end\n")}  end\n")
  assert_includes run_cli("shapeless", ""), "skip config/routes.rb (no `end` of the Cybertrain::Routes.draw block at its indentation)#{skip}"
  copy_fixture("half")
  run_cli("half", "")
  diff = manual_for(Cybertrain::CLI::Authentication.generate_with_result(copy_fixture("half_probe")), "app/controllers/application_controller.rb")
  assert patch_in("half", diff)
  output = run_cli("half", "")
  assert_includes output, "skip config/routes.rb (no `# jobs_page \"/admin/jobs\", before_action: :require_admin` comment to draw)#{skip}"
end

test "--confirmable's warnings come again at the end, with what the diffs are for (review M1, M6)" do
  copy_fixture("confirm_cli")
  output = run_cli("confirm_cli", "--confirmable")
  assert output.end_with?("IMPORTANT: app/controllers/sessions_controller.rb: until this diff is applied, an unconfirmed account's right password is refused without its message (the concern refuses it)\n" \
                          "IMPORTANT: app/controllers/registrations_controller.rb: until this diff is applied, a sign-up is mailed no confirmation link (the concern signs it in no more)\n" \
                          "\n" \
                          "next: apply the diffs above, or re-run with --force for files you never edited\n" \
                          "  # the app may not build until these diffs are applied: the files written now need them\n")
  # With nothing to apply by hand, neither is said.
  copy_fixture("confirm_forced")
  forced = run_cli("confirm_forced", "--confirmable --force")
  assert forced.index("IMPORTANT:").nil?
  assert forced.index("may not build").nil?
end

test "LineDiff.unified writes diff -u's hunks" do
  assert_equal "", Cybertrain::CLI::LineDiff.unified("x.txt", "a\nb\n", "a\nb\n")
  assert_equal "--- a/x.txt\n+++ b/x.txt\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
               Cybertrain::CLI::LineDiff.unified("x.txt", "a\nb\nc\n", "a\nB\nc\n")
  # Three lines of context; a change at the start; one line is `l` alone.
  old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n"
  assert_equal "--- a/n\n+++ b/n\n@@ -1,4 +1,4 @@\n-1\n+one\n 2\n 3\n 4\n",
               Cybertrain::CLI::LineDiff.unified("n", old, old.sub("1\n", "one\n"))
  assert_equal "--- a/n\n+++ b/n\n@@ -1 +1 @@\n-x\n+y\n", Cybertrain::CLI::LineDiff.unified("n", "x\n", "y\n")
  # An empty side is `0,0`; added lines after the last one start after it.
  assert_equal "--- a/n\n+++ b/n\n@@ -0,0 +1,2 @@\n+a\n+b\n", Cybertrain::CLI::LineDiff.unified("n", "", "a\nb\n")
  assert_equal "--- a/n\n+++ b/n\n@@ -7,3 +7,4 @@\n 7\n 8\n 9\n+10\n", Cybertrain::CLI::LineDiff.unified("n", old, "#{old}10\n")
  # Changes six same lines apart share a hunk; seven apart, they do not.
  long = +""
  20.times { |i| long << "#{i}\n" }
  six = long.sub("2\n", "two\n").sub("9\n", "nine\n")
  assert_equal 1, hunks(Cybertrain::CLI::LineDiff.unified("n", long, six))
  seven = long.sub("2\n", "two\n").sub("10\n", "ten\n")
  assert_equal "--- a/n\n+++ b/n\n@@ -1,6 +1,6 @@\n 0\n 1\n-2\n+two\n 3\n 4\n 5\n@@ -8,7 +8,7 @@\n 7\n 8\n 9\n-10\n+ten\n 11\n 12\n 13\n",
               Cybertrain::CLI::LineDiff.unified("n", long, seven)
  # A last line without its newline.
  assert_equal "--- a/n\n+++ b/n\n@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+x\n",
               Cybertrain::CLI::LineDiff.unified("n", "x", "x\n")
end

test "LineDiff.unified output applies with patch -p1" do
  cases = [
    ["a\nb\nc\n", "a\nB\nc\n"],
    ["", "new\nfile\n"],
    ["gone\n", ""],
    ["x", "x\n"],
    ["x\n", "x"],
    ["1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n", "0\n1\n2\nthree\n4\n5\n6\n7\n8\n9\n10\n11\n12\nfourteen\n15\n16\n17\n"],
    ["same\nsame\nsame\nx\nsame\nsame\n", "same\nx\nsame\nsame\nsame\nsame\ny\n"],
    [read("#{FIXTURE}/test/authentication.rb"), read("fresh/shop/test/authentication.rb")]
  ]
  Dir.mkdir("#{TMP}/patched")
  cases.each_with_index do |pair, i|
    name = "dir#{i}/f.txt"
    Dir.mkdir("#{TMP}/patched/dir#{i}")
    File.write("#{TMP}/patched/#{name}", pair[0])
    assert patch_in("patched", Cybertrain::CLI::LineDiff.unified(name, pair[0], pair[1])), "case #{i}"
    assert_equal pair[1], read("#{TMP}/patched/#{name}") if File.exist?("#{TMP}/patched/#{name}")
    assert_equal "", pair[1] unless File.exist?("#{TMP}/patched/#{name}")
  end
end

Cybertrain::Test.run!
