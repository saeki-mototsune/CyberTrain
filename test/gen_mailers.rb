require "tmpdir"
require "fileutils"
require "cybertrain/test"
require "cybertrain/generator"
require "cybertrain/generator/mailer_scan"
require "cybertrain/generator/mailers_emitter"
require "cybertrain/generator/manifest"
require_relative "support/file_tree"

# The mailer generator as text (docs/design.md D98; CRuby-portable, no
# database): Gen::MailerScan reads app/mailers/**/*.rb, Gen::MailersEmitter
# writes gen/mailers.rb. The fixture app's mailers (whose checked-in
# gen/mailers.rb test/mailer_classes.rb compiles and runs), then small
# app trees for the refusals and the manifest.
FIXTURE = "test/fixtures/gen_mailers"
TMP = Dir.mktmpdir("cybertrain-gen-mailers")

at_exit { FileTree.remove(TMP) }

def app_tree(files)
  root = Dir.mktmpdir("app", TMP)
  files.each do |rel, source|
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end
  root
end

def scan(root)
  Cybertrain::Gen::MailerScan.scan_dir("#{root}/app/mailers")
end

# The message of the MailerScan::Error scanning `root` raises.
def refusal(root)
  scan(root)
  flunk("expected Gen::MailerScan::Error")
  ""
rescue Cybertrain::Gen::MailerScan::Error => e
  Cybertrain::Test.count_assertion
  e.message
end

BASE_MAILER = "class ApplicationMailer < Cybertrain::Mailer::Base\nend\n"

def one_mailer(body)
  app_tree("app/mailers/application_mailer.rb" => BASE_MAILER,
           "app/mailers/note_mailer.rb" => "class NoteMailer < ApplicationMailer\n#{body}end\n")
end

test "the fixture's mailer classes in load order, the module left out" do
  infos = scan(FIXTURE)
  assert_equal ["ApplicationMailer", "Admin::NoticeMailer", "UserMailer"], infos.map { |i| i.mailer_name }
  assert_equal ["Cybertrain::Mailer::Base", "ApplicationMailer", "ApplicationMailer"], infos.map { |i| i.mailer_super }
  base = infos[0]
  assert_equal "\"notifications@example.com\"", base.mailer_from
  assert base.mailer_layout_declared
  assert_equal "mailer", base.mailer_layout_name
  assert_equal [], base.mailer_actions.map { |a| a.action_name }
  assert_equal ["footer"], base.mailer_ivars
  notice = infos[1]
  assert notice.mailer_layout_declared
  assert_equal "", notice.mailer_layout_name
  assert_equal ["module"], notice.mailer_scopes
  user = infos[2]
  assert_equal ["welcome", "reset", "plain_note", "empty_note"], user.mailer_actions.map { |a| a.action_name }
  assert_equal "user, greeting = \"Hello\", copy: false", user.mailer_actions[0].action_params
  assert_equal "user, greeting, copy: copy", user.mailer_actions[0].action_args
  assert_equal "", user.mailer_actions[1].action_params
  assert_equal ["name", "greeting", "logo", "user", "url"], user.mailer_ivars
end

test "the emitter writes the fixture's checked-in gen/mailers.rb" do
  assert_equal File.read("#{FIXTURE}/gen/mailers.rb"), Cybertrain::Gen::MailersEmitter.emit(scan(FIXTURE))
end

test "view_assigns takes the ancestors' instance variables after the class's own" do
  out = Cybertrain::Gen::MailersEmitter.emit(scan(FIXTURE))
  assert out.include?("    { \"name\" => @name, \"greeting\" => @greeting, \"logo\" => @logo, \"user\" => @user, \"url\" => @url, \"footer\" => @footer }\n")
  assert out.include?("  def self.welcome(user, greeting = \"Hello\", copy: false)\n    with({}).welcome(user, greeting, copy: copy)\n  end\n")
end

test "a parameter list continued over lines is read whole" do
  infos = scan(one_mailer("  def note(to,\n           subject: \"x\")\n    mail(to: to, subject: subject)\n  end\n"))
  assert_equal "to, subject: \"x\"", infos[1].mailer_actions[0].action_params.gsub(/\s+/, " ")
  assert_equal "to, subject: subject", infos[1].mailer_actions[0].action_args
end

test "a parameter list without parentheses ends at the semicolon of a one-line def" do
  infos = scan(one_mailer("  def note to, subject = \"a;b\"; mail(to: to, subject: subject); end\n"))
  assert_equal "to, subject = \"a;b\"", infos[1].mailer_actions[0].action_params
  assert_equal "to, subject", infos[1].mailer_actions[0].action_args
end

test "a subclass dispatches its ancestors' actions through itself, its own first" do
  root = app_tree("app/mailers/application_mailer.rb" => BASE_MAILER,
                  "app/mailers/a_parent_mailer.rb" => "class AParentMailer < ApplicationMailer\n  def welcome(user)\n    nil\n  end\n\n" \
                                                      "  def receipt\n    nil\n  end\nend\n",
                  "app/mailers/b_child_mailer.rb" => "class BChildMailer < AParentMailer\n  def receipt(order)\n    nil\n  end\nend\n",
                  "app/mailers/c_empty_mailer.rb" => "class CEmptyMailer < AParentMailer\nend\n")
  out = Cybertrain::Gen::MailersEmitter.emit(scan(root))
  from = out.index("class BChildMailer").to_i
  child = out[from, out.index("class CEmptyMailer").to_i - from].to_s
  assert child.include?("      mailer = BChildMailer.new\n      mailer.mailer_setup(@params, \"receipt\")\n      mailer.receipt(order)\n")
  assert child.include?("      mailer = BChildMailer.new\n      mailer.mailer_setup(@params, \"welcome\")\n")
  assert_not child.include?("mailer.receipt\n")
  empty = out[out.index("class CEmptyMailer"), out.size].to_s
  assert empty.include?("  def self.with(params)\n")
  assert empty.include?("      mailer = CEmptyMailer.new\n      mailer.mailer_setup(@params, \"welcome\")\n")
end

test "refusals: splats, reserved names, a default that is not from: alone, a layout that is not literal" do
  splat = refusal(one_mailer("  def note(*names)\n    nil\n  end\n"))
  assert splat.end_with?("app/mailers/note_mailer.rb:2: note: a mailer action takes named parameters only (no *, ** or &), " \
                         "so gen/mailers.rb can pass them on")
  reserved = refusal(one_mailer("  def params\n    nil\n  end\n"))
  assert reserved.end_with?(":2: params is a method of Cybertrain::Mailer::Base or one gen/mailers.rb writes; give the action another name")
  with = refusal(one_mailer("  def self.with(x)\n    nil\n  end\n"))
  assert with.end_with?(":2: with is a class method gen/mailers.rb writes into every mailer; give the method another name")
  reply = refusal(one_mailer("  default from: \"a@example.com\", reply_to: \"b@example.com\"\n"))
  assert reply.end_with?("-- write `default from: \"address\"` on one line (only from: is read)")
  layout = refusal(one_mailer("  layout name_of_layout\n"))
  assert layout.end_with?("-- write layout \"name\" (a literal String) or layout false")
  order = refusal(app_tree("app/mailers/application_mailer.rb" => BASE_MAILER,
                           "app/mailers/a_mailer.rb" => "class AMailer < BMailer\nend\n",
                           "app/mailers/b_mailer.rb" => "class BMailer < ApplicationMailer\nend\n"))
  assert order.include?("a_mailer.rb:1: BMailer is defined in ")
end

test "private and protected methods are not actions; public after them is" do
  infos = scan(one_mailer("  def a\n    nil\n  end\n\n  protected\n\n  def b\n    @hidden = 1\n  end\n\n  public def f\n    nil\n  end\n\n" \
                          "  def g\n    nil\n  end\n\n  public\n\n" \
                          "  def c = nil\n  private def d\n    nil\n  end\nend\nclass Helper\n  def e\n    nil\n  end\n"))
  assert_equal ["a", "f", "c"], infos[1].mailer_actions.map { |x| x.action_name }
  assert_equal ["hidden"], infos[1].mailer_ivars
end

test "no mailer class: nothing to write, and the manifest requires no gen/mailers" do
  root = app_tree("app/mailers/passwords_mailer.rb" => "module PasswordsMailer\n  def self.reset(u)\n    nil\n  end\nend\n")
  assert_equal [], scan(root)
  manifest = Cybertrain::Gen::Manifest.emit_with_models(root, [])
  assert manifest.include?("require_relative \"../app/mailers/passwords_mailer\"\n")
  assert_not manifest.include?("require_relative \"mailers\"")
end

test "the manifest loads application_mailer first, then the others, then gen/mailers" do
  manifest = Cybertrain::Gen::Manifest.emit_with_models(FIXTURE, [])
  first = manifest.index("../app/mailers/application_mailer\"")
  admin = manifest.index("../app/mailers/admin/notice_mailer\"")
  gen = manifest.index("require_relative \"mailers\"\n")
  assert first < admin
  assert admin < gen
end

Cybertrain::Test.run!
