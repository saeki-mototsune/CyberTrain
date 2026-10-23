# `cybertrain generate attachment MODEL FIELD [--any]`: a file attached to a
# model (`cover` on `Post`), as code the application owns (docs/design.md
# D15, D16). The framework supplies the parts that are easy to get wrong
# (the multipart parser, Cybertrain::UploadedFile, Cybertrain::BlobStore,
# Controller#send_blob); this writes the rest:
#
#   db/migrate/*_add_cover_to_posts.rb   five metadata columns
#   test/attachment_post_cover.rb, test/support/app_test.rb
#
# and one-time edits, each guarded by a marker so that running the
# generator again changes nothing:
#
#   app/models/post.rb                    constants, callbacks and cover_* methods
#   app/controllers/posts_controller.rb   `def cover` (the download, loaded by
#                                         `before_action :set_post`), `cover_file=`
#                                         in create and update
#   config/routes.rb                      get "/posts/:id/cover"
#   app/views/posts/_form.html.erb, show.html.erb   (scaffold shape only)
#   .gitignore                            /storage/uploads/
#
# The bytes are never in the database (SQLite binds text, and stops at a
# NUL): BlobStore writes them under storage/uploads/ and the model keeps a
# random key plus the server-detected type, size and SHA-256. Without
# --any only PNG, JPEG, GIF and WebP are accepted, and
# Controller#send_blob serves those inline and anything else as a download.
#
# `generate scaffold post title:string cover:attachment` ends in the same
# edits (Scaffold.generate calls install_code); it writes the columns in
# the create_table migration itself, so there is no second migration.
#
# Loaded by cybertrain/cli.rb together with scaffold.rb (whose Scaffold
# and InvalidArgument it uses) and authentication.rb (indent and
# insert_after_line).
require "cybertrain/generator/inflector"
require "cybertrain/ident"
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/authentication"

module Cybertrain
  module CLI
    # The names one attachment is generated from: model `post`, field
    # `cover` give Post / posts / PostsController, COVER_*, cover_key ...
    class AttachmentSpec
      attr_reader :singular, :plural, :class_name, :plural_class, :field, :any

      # `model` is snake_case or CamelCase, singular or plural ("post",
      # "Post" and "posts" all name Post).
      def initialize(model, field, any)
        @singular = Inflector.singularize(Inflector.underscore(model))
        @plural = Inflector.pluralize(@singular)
        @class_name = Inflector.camelize(@singular)
        @plural_class = Inflector.camelize(@plural)
        @field = field
        @any = any
      end

      def upper
        @field.upcase
      end

      def human_field
        Templates.humanize(@field)
      end

      # `text` (a template of the generated files) with its <<placeholders>>
      # filled in. The templates are quoted heredocs so that the interpolation
      # of the generated code needs no escaping.
      def expand(text)
        out = text.gsub("<<Model>>", @class_name)
        out = out.gsub("<<model>>", @singular)
        out = out.gsub("<<plural>>", @plural)
        out = out.gsub("<<Plural>>", @plural_class)
        out = out.gsub("<<FIELD>>", upper)
        out = out.gsub("<<Field>>", human_field)
        out = out.gsub("<<field>>", @field)
        out
      end
    end

    module Attachment
      MARK = "cybertrain:attachment"
      BACKUP_NOTE = "note: uploaded files live in storage/uploads/; back it up (and mount it as a volume) together with the SQLite file"
      IMAGE_TYPES_LITERAL = "[\"image/png\", \"image/jpeg\", \"image/gif\", \"image/webp\"]"

      # Returns the paths it created. Raises InvalidArgument, before anything
      # is written, when the field name is unusable or `root` is not an
      # application with that model, its controller and a routes file.
      def self.generate(root, model, field, any)
        spec = AttachmentSpec.new(model, field, any)
        check_names!(spec)

        routes_path = File.join(root, "config/routes.rb")
        raise InvalidArgument, "#{routes_path} not found: run this inside a cybertrain app" unless File.exist?(routes_path)
        raise InvalidArgument, "#{routes_path} has no `#{Scaffold::DRAW_LINE}` line" if File.read(routes_path).index(Scaffold::DRAW_LINE).nil?

        model_path = File.join(root, model_file(spec))
        raise InvalidArgument, "#{model_path} not found: generate the model first (cybertrain generate scaffold #{spec.singular} ...)" unless File.exist?(model_path)
        raise InvalidArgument, "#{model_path} has no `class #{spec.class_name}` line" if line_start(File.read(model_path), "class #{spec.class_name}", "class") < 0

        controller_path = File.join(root, controller_file(spec))
        raise InvalidArgument, "#{controller_path} not found: generate the controller first (cybertrain generate scaffold #{spec.singular} ...)" unless File.exist?(controller_path)
        raise InvalidArgument, "#{controller_path} has no `#{controller_line(spec)}` line" if line_start(File.read(controller_path), controller_line(spec), "start") < 0

        # Only the owner's table counts (products may have a cover when posts
        # do), and a column this generator added (the model has its marker)
        # is a re-run after `db migrate`, which reports identical.
        schema_path = File.join(root, "db/schema.rb")
        if File.exist?(schema_path) && schema_column?(File.read(schema_path), spec.plural, "#{field}_key") &&
           File.read(model_path).index(model_marker(spec)).nil?
          raise InvalidArgument, "#{schema_path} already has a \"#{field}_key\" column in \"#{spec.plural}\": #{spec.class_name} already has a #{field}, or pick another field name"
        end

        created = Array.new(0) { "" }
        record(created, root, migration_path(root, spec), migration(spec))
        # The views first: the test written by install_code asserts on the
        # show page only when it renders the file.
        add_form_field(root, spec)
        add_show_markup(root, spec)
        install_code(root, spec, created)
        created
      end

      # Everything but the migration and the views: the model block, the
      # download action, the create/update assignments, the route, the
      # .gitignore line and the test. Shared with the scaffold, which writes
      # the columns and views itself. Appends the paths it created.
      def self.install_code(root, spec, created)
        add_model_block(root, spec)
        add_action(root, spec)
        add_public_download(root, spec)
        add_assignments(root, spec)
        add_route(root, spec)
        add_gitignore(root)
        record(created, root, "test/support/app_test.rb", Authentication.app_test_support)
        record(created, root, test_file(spec), attachment_test(root, spec))
        nil
      end

      def self.record(created, root, path, content)
        created << path if Templates.write(root, path, content) == "create"
        nil
      end

      # ---- names --------------------------------------------------------

      def self.model_file(spec)
        "app/models/#{spec.singular}.rb"
      end

      def self.controller_file(spec)
        "app/controllers/#{spec.plural}_controller.rb"
      end

      def self.controller_line(spec)
        "class #{spec.plural_class}Controller < ApplicationController"
      end

      def self.test_file(spec)
        "test/attachment_#{spec.singular}_#{spec.field}.rb"
      end

      def self.route_line(spec)
        "get \"/#{spec.plural}/:id/#{spec.field}\", to: \"#{spec.plural}##{spec.field}\", as: \"#{spec.singular}_#{spec.field}\""
      end

      # Whether db/schema.rb's `create_table "<table>"` block has a column
      # `column` (the schema dumper writes `s.create_table "posts" do |t|`,
      # one `t.<type> "<name>", ...` line per column and `end`).
      def self.schema_column?(source, table, column)
        head = "create_table \"#{table}\""
        inside = false
        found = false
        source.each_line do |raw|
          stripped = raw.strip
          if stripped.start_with?(head) || stripped.start_with?("s.#{head}")
            inside = true
          elsif inside && stripped == "end"
            inside = false
          elsif inside && !stripped.index("\"#{column}\"").nil?
            found = true
          end
        end
        found
      end

      # The marker comment that opens the model block of this attachment.
      def self.model_marker(spec)
        "# #{MARK} #{spec.field} "
      end

      # The field must be a lowercase identifier, and neither it nor the
      # five columns made from it may be a name the model generator would
      # rename (Ident), nor a method the controller already has (the
      # download action is `def <field>`; Templates.attachment_action_clash?).
      def self.check_names!(spec)
        field = spec.field
        raise InvalidArgument, "bad model name '#{spec.singular}'" unless Templates.identifier?(spec.singular)
        raise InvalidArgument, "bad field name '#{field}' (lowercase letters, digits and _, starting with a letter)" unless field_name?(field)
        if Templates.attachment_action_clash?(field, spec.singular)
          raise InvalidArgument, "'#{field}' would redefine a method of #{spec.plural_class}Controller (the download action is `def #{field}`); pick another field name"
        end

        Scaffold.refuse_unusable!(field, "attachment")
        Templates.attachment_column_names(field).each { |col| Scaffold.refuse_unusable!(col, "attachment column") }
        nil
      end

      # /\A[a-z][a-z0-9_]*\z/
      def self.field_name?(name)
        return false if name.empty?

        i = 0
        while i < name.bytesize
          b = name.getbyte(i)
          lower = b >= 97 && b <= 122
          digit_or_underscore = (b >= 48 && b <= 57) || b == 95
          return false unless lower || (i > 0 && digit_or_underscore)

          i += 1
        end
        true
      end

      # ---- the migration ------------------------------------------------

      # db/migrate/<version>_add_cover_to_posts.rb, or the existing one.
      def self.migration_path(root, spec)
        suffix = "_add_#{spec.field}_to_#{spec.plural}.rb"
        existing = Dir.glob(File.join(root, "db/migrate/*#{suffix}")).sort
        return "db/migrate/#{File.basename(existing[0])}" unless existing.empty?

        "db/migrate/#{Scaffold.next_version(root, Scaffold.timestamp)}#{suffix}"
      end

      # `default:` is SQL literal text (migration.rb), hence "''" and "0".
      # Not null with "" / 0 as "nothing attached" keeps the model's readers
      # a plain String and Integer under Spinel (NOTES rules 7/11).
      def self.migration(spec)
        buf = +""
        buf << "class Add#{Inflector.camelize(spec.field)}To#{spec.plural_class} < Cybertrain::Migration::Base\n"
        buf << "  def change\n"
        Templates::ATTACHMENT_COLUMNS.each do |col|
          buf << "    add_column \"#{spec.plural}\", \"#{spec.field}_#{col[0]}\", :#{col[1]}, null: false, default: \"#{col[2]}\"\n"
        end
        buf << "  end\n"
        buf << "end\n"
        buf
      end

      # ---- edits ----------------------------------------------------------

      # Inserts the attachment block right after the model's class line, once
      # (the block's first comment line is the marker).
      def self.add_model_block(root, spec)
        path = model_file(spec)
        full = File.join(root, path)
        source = File.read(full)
        unless source.index(model_marker(spec)).nil?
          puts "identical #{path} (attachment #{spec.field} already added)"
          return false
        end

        at = line_end(source, line_start(source, "class #{spec.class_name}", "class"))
        if at < 0
          puts "skip #{path} (no `class #{spec.class_name}` line): add this inside the class:"
          puts Authentication.indent(model_block(spec))
          return false
        end

        File.write(full, insert_at(source, at, Authentication.indent(model_block(spec)) + "\n"))
        puts "insert #{path} (attachment #{spec.field})"
        true
      end

      # Inserts the download action right after the controller's class line,
      # once (`def cover` marks it). The record comes from the controller's
      # own `before_action :set_post`, with :cover added to its only: list,
      # so the download is scoped exactly like show: an app that limits
      # set_post to the signed-in user's posts limits the file too. A
      # controller without that before_action gets an action that looks the
      # record up itself, and a warning that this lookup is unscoped.
      def self.add_action(root, spec)
        path = controller_file(spec)
        full = File.join(root, path)
        source = File.read(full)
        unless line_start(source, "def #{spec.field}", "exact") < 0
          puts "identical #{path} (def #{spec.field} already added)"
          return false
        end

        coverage = set_record_coverage(source, spec, spec.field)
        scoped = coverage != "no"
        at = line_end(source, line_start(source, controller_line(spec), "start"))
        if at < 0
          puts "skip #{path} (no `#{controller_line(spec)}` line): add this to the controller:"
          puts Authentication.indent(action_block(spec, false))
          return false
        end

        source = add_to_only_list(source, spec, spec.field) if coverage == "add"
        block = Authentication.indent(action_block(spec, scoped))
        # Below the before_action line when there is one, so that it stays
        # the first thing in the class. The block ends in a blank line; it
        # moves to the front, since that line is usually followed by one.
        before = set_record_line(source, spec)
        if before >= 0
          at = line_end(source, before)
          block = "\n" + block[0, block.size - 1].to_s
        else
          at = line_end(source, line_start(source, controller_line(spec), "start"))
        end
        File.write(full, insert_at(source, at, block))
        puts "insert #{path} (def #{spec.field})"
        puts "insert #{path} (:#{spec.field} in before_action :set_#{spec.singular})" if coverage == "add"
        unless scoped
          puts "warning: #{path} has no `before_action :set_#{spec.singular}` for :#{spec.field}, so def #{spec.field} looks the #{spec.singular} up with an unscoped #{spec.class_name}.find(params[:id]); if your actions limit which records a user may see, limit this lookup the same way"
        end
        true
      end

      # The image is shown on the show page, so when `allow_unauthenticated_access`
      # makes show public (step 13 of the tutorial: `only: [:index, :show]`),
      # the download joins it; otherwise a visitor sees a broken image. Where
      # show needs a signed-in user the download does too, and nothing changes.
      # Only when both find the record through `before_action :set_post`: a
      # download with its own unscoped find could hand a visitor the file of
      # a record show would not show, so that one is left for the app to open.
      def self.add_public_download(root, spec)
        path = controller_file(spec)
        full = File.join(root, path)
        source = File.read(full)
        return false unless download_access(source, spec) == "add"

        unless set_record_coverage(source, spec, spec.field) == "yes" && set_record_coverage(source, spec, "show") == "yes"
          puts "skip #{path} (:show is public, but def #{spec.field} does not load the #{spec.singular} through before_action :set_#{spec.singular} as show does): add :#{spec.field} to allow_unauthenticated_access yourself if visitors may download it"
          return false
        end

        File.write(full, add_to_only_list_at(source, public_access_line(source), spec.field))
        puts "insert #{path} (:#{spec.field} in allow_unauthenticated_access, since :show is public)"
        true
      end

      # Who may download: "public" when allow_unauthenticated_access already
      # covers the action (no list, an only: list with it, an except: list
      # without it), "add" when its one-line only: list makes show public but
      # does not list the action, "private" otherwise (no such line, or show
      # needs a signed-in user).
      def self.download_access(source, spec)
        at = public_access_line(source)
        return "private" if at < 0

        stripped = source[at, line_end(source, at) - at].to_s.strip
        field = list_coverage(stripped, spec.field)
        return "public" if field == "yes"
        return "add" if field == "add" && list_coverage(stripped, "show") == "yes"

        "private"
      end

      # Offset of the line `allow_unauthenticated_access` (alone, or followed
      # by its arguments), or -1.
      def self.public_access_line(source)
        head = "allow_unauthenticated_access"
        offset = 0
        hit = -1
        source.each_line do |raw|
          stripped = raw.strip
          if hit < 0 && stripped.start_with?(head)
            rest = stripped[head.size, stripped.size - head.size].to_s
            hit = offset if rest == "" || rest.start_with?(" ") || rest.start_with?("(")
          end
          offset += raw.size
        end
        hit
      end

      # `@post.cover_file = params.nested(:post).upload(:cover)` after the
      # line that builds the record in create, and in update once @post is
      # loaded: after `@post = Post.find(params[:id])` when update has that
      # line, else right after `def update` when `before_action :set_post`
      # covers update. permit stays as it is: it returns Strings only, so a
      # file can only arrive through this explicit assignment. An action the
      # scaffold shape does not have gets the line printed instead.
      #
      # `nested`, not `require`: a form whose only field is the file sends no
      # `post[...]` key when no file is chosen (the parser drops the empty
      # input), and that edit keeps the stored file rather than being a 400.
      # For the same reason a `<model>_params` that permits nothing (a model
      # whose only fields are files) is switched to nested.
      def self.add_assignments(root, spec)
        path = controller_file(spec)
        full = File.join(root, path)
        line = assignment_line(spec)
        s = spec.singular
        source = File.read(full)
        build = "@#{s} = #{spec.class_name}.new(#{s}_params)"
        updated = insert_line_after(source, line_start(source, build, "exact"), 0, line)
        if updated == ""
          puts "skip #{path} (no `#{build}` line): add `#{line}` to create"
        elsif updated == source
          puts "identical #{path} (#{spec.field}_file= in create)"
        else
          puts "insert #{path} (#{spec.field}_file= in create)"
        end
        source = updated unless updated == ""

        updated = ""
        def_at = line_start(source, "def update", "exact")
        find = "@#{s} = #{spec.class_name}.find(params[:id])"
        if def_at >= 0
          find_at = line_start_between(source, find, line_end(source, def_at), method_end(source, def_at))
          if find_at >= 0
            updated = insert_line_after(source, find_at, 0, line)
          elsif set_record_coverage(source, spec, "update") == "yes"
            updated = insert_line_after(source, def_at, 2, line)
          end
        end
        if updated == ""
          puts "skip #{path} (update does not load @#{s} with `#{find}` nor through `before_action :set_#{s}`): add `#{line}` to update once @#{s} is loaded"
        elsif updated == source
          puts "identical #{path} (#{spec.field}_file= in update)"
        else
          puts "insert #{path} (#{spec.field}_file= in update)"
        end
        source = updated unless updated == ""

        strict = "params.require(:#{s}).permit()"
        unless source.index(strict).nil?
          source = source.sub(strict, "params.nested(:#{s}).permit()")
          puts "insert #{path} (#{s}_params reads params.nested(:#{s}): the form may send only files)"
        end

        File.write(full, source)
        true
      end

      # Inserts the download route after the draw line, once.
      def self.add_route(root, spec)
        routes_path = File.join(root, "config/routes.rb")
        line = route_line(spec)
        source = File.read(routes_path)
        unless source.index(line).nil?
          puts "identical route #{spec.singular}_#{spec.field}"
          return false
        end

        File.write(routes_path, Authentication.insert_after_line(source, Scaffold::DRAW_LINE, Authentication.indent(line + "\n")))
        puts "route #{spec.singular}_#{spec.field} (GET /#{spec.plural}/:id/#{spec.field})"
        true
      end

      # Appends /storage/uploads/ to .gitignore, once. The templates for a
      # new app have it already.
      def self.add_gitignore(root)
        path = File.join(root, ".gitignore")
        unless File.exist?(path)
          puts "skip .gitignore (not found): ignore /storage/uploads/"
          return false
        end

        source = File.read(path)
        present = false
        source.each_line { |l| present = true if l.strip == "/storage/uploads/" }
        if present
          puts "identical .gitignore (/storage/uploads/ already ignored)"
          return false
        end

        source += "\n" unless source.empty? || source.end_with?("\n")
        File.write(path, source + "/storage/uploads/\n")
        puts "insert .gitignore (/storage/uploads/)"
        true
      end

      # The scaffold's form gets multipart: true and the file input; any
      # other shape of form is told what to add.
      def self.add_form_field(root, spec)
        path = "app/views/#{spec.plural}/_form.html.erb"
        full = File.join(root, path)
        s = spec.singular
        unless File.exist?(full)
          puts "skip #{path} (not found): use form_with(model: #{s}, multipart: true) and #{file_input(spec)}"
          return false
        end

        source = File.read(full)
        if name_present?(source, "f.file_field :#{spec.field}")
          puts "identical #{path} (file field already added)"
          return false
        end

        updated = source
        plain = "<%= form_with(model: #{s}) do |f| %>"
        updated = updated.sub(plain, "<%= form_with(model: #{s}, multipart: true) do |f| %>") unless updated.index(plain).nil?
        actions = line_start(updated, "<div class=\"actions\">", "exact")
        if updated.index("multipart: true").nil? || actions < 0
          puts "skip #{path} (not the scaffold's form): use form_with(model: #{s}, multipart: true) and #{file_input(spec)}"
          return false
        end

        File.write(full, insert_at(updated, actions, form_block(spec)))
        puts "insert #{path} (#{spec.field} file field, multipart: true)"
        true
      end

      # The cover image (or, with --any, a download link) after the <h1> of
      # the scaffold's show page.
      def self.add_show_markup(root, spec)
        path = "app/views/#{spec.plural}/show.html.erb"
        full = File.join(root, path)
        markup = show_markup(spec)
        unless File.exist?(full)
          puts "skip #{path} (not found): show the file with #{markup}"
          return false
        end

        source = File.read(full)
        if name_present?(source, "@#{spec.singular}.#{spec.field}_url")
          puts "identical #{path} (#{spec.field} already shown)"
          return false
        end

        at = line_end(source, line_start(source, "<h1>", "start"))
        if at < 0
          puts "skip #{path} (no <h1>): show the file with #{markup}"
          return false
        end

        File.write(full, insert_at(source, at, markup + "\n"))
        puts "insert #{path} (#{spec.field})"
        true
      end

      # ---- line helpers ---------------------------------------------------

      # Offset where the first line matching `text` starts, or -1. `mode`
      # "exact": the stripped line equals text; "start": it starts with
      # text; "class": a `class Name` line (the name ends at a space,
      # `<`, `;` or the end of the line, so `class Post` is not `class PostTag`).
      def self.line_start(source, text, mode)
        offset = 0
        source.each_line do |raw|
          stripped = raw.strip
          hit = false
          if mode == "exact"
            hit = stripped == text
          elsif mode == "start"
            hit = stripped.start_with?(text)
          else
            rest = stripped.start_with?(text) ? stripped[text.size, stripped.size - text.size].to_s : "x"
            hit = rest == "" || rest.start_with?(" ") || rest.start_with?(";")
          end
          return offset if hit

          offset += raw.size
        end
        -1
      end

      # Offset just after the line that starts at `start` (its newline
      # included), or -1 when start is -1.
      def self.line_end(source, start)
        return -1 if start < 0

        eol = source.index("\n", start)
        eol.nil? ? source.size : eol + 1
      end

      # `source` with `block` inserted at `offset`; a source whose last
      # line has no newline gets one first.
      def self.insert_at(source, offset, block)
        head = source[0, offset].to_s
        head += "\n" unless head.empty? || head.end_with?("\n")
        out = +""
        out << head << block << source[offset, source.size - offset].to_s
        out << "\n" unless out.end_with?("\n")
        out
      end

      # `source` with `text` (indented `extra` columns deeper than the anchor)
      # inserted after the anchor line, the line that starts at offset `at`.
      # Returns `source` itself when the method around the anchor already
      # has a line `text` anywhere (a second attachment's line may sit
      # between the anchor and this one), and "" when `at` is -1.
      def self.insert_line_after(source, at, extra, text)
        return "" if at < 0
        return source if line_start_between(source, text, method_start(source, at), method_end(source, at)) >= 0

        eol = line_end(source, at)
        anchor_line = source[at, eol - at].to_s
        pad = +""
        (anchor_line.size - anchor_line.lstrip.size + extra).times { pad << " " }
        insert_at(source, eol, "#{pad}#{text}\n")
      end

      # Whether a line starts with `def ` or is a visibility keyword: where
      # one method's body ends.
      def self.method_boundary?(stripped)
        stripped.start_with?("def ") || stripped == "private" || stripped == "protected" || stripped == "public"
      end

      # Offset of the `def` line of the method around offset `at` (the last
      # `def` line starting at or before it), or 0.
      def self.method_start(source, at)
        found = 0
        offset = 0
        source.each_line do |raw|
          found = offset if offset <= at && raw.strip.start_with?("def ")
          offset += raw.size
        end
        found
      end

      # Offset of the first method boundary after the line at `at`, or the
      # end of `source`.
      def self.method_end(source, at)
        after = line_end(source, at)
        found = source.size
        offset = 0
        source.each_line do |raw|
          found = offset if offset >= after && found == source.size && method_boundary?(raw.strip)
          offset += raw.size
        end
        found
      end

      # Offset of the first line in [from, to) whose stripped text is
      # `text`, or -1.
      def self.line_start_between(source, text, from, to)
        offset = 0
        hit = -1
        source.each_line do |raw|
          hit = offset if hit < 0 && offset >= from && offset < to && raw.strip == text
          offset += raw.size
        end
        hit
      end

      # Whether `piece` occurs in `source` as a whole name, not followed by
      # a letter, digit or _: `f.file_field :cover` is not in a form that
      # only has `f.file_field :cover_image`.
      def self.name_present?(source, piece)
        at = source.index(piece)
        until at.nil?
          after = at + piece.size
          return true if after >= source.size || !name_char?(source[after, 1].to_s)

          at = source.index(piece, at + 1)
        end
        false
      end

      def self.name_char?(ch)
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
      end

      # How the controller's `before_action :set_post` covers `action`:
      # "yes" when it runs for it (no only:, or only: lists it, or an except:
      # that does not), "add" when it has a one-line `only: [...]` list
      # without it, "no" when there is no such line or its only: is not a
      # list this can read.
      def self.set_record_coverage(source, spec, action)
        at = set_record_line(source, spec)
        return "no" if at < 0

        list_coverage(source[at, line_end(source, at) - at].to_s.strip, action)
      end

      # How a callback line (`before_action :set_post, only: [...]`,
      # `allow_unauthenticated_access except: [...]`) covers `action`: "yes",
      # "add" (a one-line only: list without it) or "no", as
      # set_record_coverage describes.
      # except: wins over only: (Callback#applies? checks both), and a list
      # this cannot read answers "no".
      def self.list_coverage(stripped, action)
        token = ":#{action}"
        except_at = stripped.index("except:")
        only_at = stripped.index("only:")
        unless except_at.nil?
          return "no" if bracket_open(stripped, except_at + 7) < 0
          return "no" if list_has?(stripped, except_at + 7, token)
        end
        return "yes" if only_at.nil?
        return "no" if bracket_open(stripped, only_at + 5) < 0

        list_has?(stripped, only_at + 5, token) ? "yes" : "add"
      end

      # Offset of the line `before_action :set_post` (alone or followed by
      # a comma, so not `:set_post_tag`), or -1.
      def self.set_record_line(source, spec)
        head = "before_action :set_#{spec.singular}"
        offset = 0
        hit = -1
        source.each_line do |raw|
          stripped = raw.strip
          if hit < 0 && stripped.start_with?(head)
            rest = stripped[head.size, stripped.size - head.size].to_s
            hit = offset if rest == "" || rest.start_with?(",")
          end
          offset += raw.size
        end
        hit
      end

      # Offset of the `[` that follows offset `from` in `line` (after
      # spaces) when a `]` closes it on the same line, or -1.
      def self.bracket_open(line, from)
        i = from
        i += 1 while i < line.size && line[i, 1] == " "
        return -1 unless line[i, 1] == "["
        return -1 if line.index("]", i).nil?

        i
      end

      # Whether the bracketed list after offset `from` in `line` has the
      # item `token` (":show"); false when there is no such list.
      def self.list_has?(line, from, token)
        open = bracket_open(line, from)
        return false if open < 0

        close = line.index("]", open).to_i
        found = false
        line[open + 1, close - open - 1].to_s.split(",").each { |item| found = true if item.strip == token }
        found
      end

      # `source` with `:action` appended to the only: list of `before_action
      # :set_post` (set_record_coverage answered "add").
      def self.add_to_only_list(source, spec, action)
        add_to_only_list_at(source, set_record_line(source, spec), action)
      end

      # `source` with `:action` appended to the only: list of the line at
      # offset `at`.
      def self.add_to_only_list_at(source, at, action)
        eol = line_end(source, at)
        line = source[at, eol - at].to_s
        open = line.index("[", line.index("only:").to_i).to_i
        close = line.index("]", open).to_i
        inner = line[open + 1, close - open - 1].to_s
        sep = inner.strip.empty? ? "" : ", "
        updated = line[0, close].to_s + "#{sep}:#{action}" + line[close, line.size - close].to_s
        source[0, at].to_s + updated + source[eol, source.size - eol].to_s
      end

      # ---- the generated code (quoted templates, filled by AttachmentSpec) ----

      def self.assignment_line(spec)
        "@#{spec.singular}.#{spec.field}_file = params.nested(:#{spec.singular}).upload(:#{spec.field})"
      end

      def self.file_input(spec)
        accept = spec.any ? "" : ", accept: \"#{Templates::ATTACHMENT_ACCEPT}\""
        "<%= f.file_field :#{spec.field}#{accept} %>"
      end

      def self.form_block(spec)
        "  <div class=\"field\">\n    <%= f.label :#{spec.field} %>\n    #{file_input(spec)}\n  </div>\n\n"
      end

      def self.show_markup(spec)
        s = spec.singular
        f = spec.field
        if spec.any
          "<% if @#{s}.#{f}_attached? %><p><a href=\"<%= @#{s}.#{f}_url %>\"><%= @#{s}.#{f}_filename %></a></p><% end %>"
        else
          "<% if @#{s}.#{f}_attached? %><p><img src=\"<%= @#{s}.#{f}_url %>\" alt=\"<%= @#{s}.#{f}_filename %>\"></p><% end %>"
        end
      end

      # The block inserted (indented) after the model's class line. The hook
      # methods are public because the callback blocks get the record, not
      # an implicit self (as in the authentication generator's User).
      def self.model_block(spec)
        types = spec.any ? "Array.new(0) { \"\" }" : IMAGE_TYPES_LITERAL
        text = MODEL_BLOCK.sub("<<types>>", types)
        text = text.sub("<<type_check>>", spec.any ? "" : TYPE_CHECK_LINE)
        spec.expand(text)
      end

      MODEL_BLOCK = <<~'RUBY'
        # cybertrain:attachment <<field>> -- written by `cybertrain generate attachment`; yours to change.
        # The bytes live in storage/uploads (Cybertrain::BlobStore), never in the
        # database: the five <<field>>_* columns hold their key and metadata. The type
        # stored is the one the server detected from the bytes, never the client's.
        # <<FIELD>>_MAX_BYTES must stay at or below config.max_upload_bytes (5 MiB), or a
        # larger file is a 400 from the parser instead of the 422 below.
        <<FIELD>>_TYPES = <<types>>
        <<FIELD>>_MAX_BYTES = 2_097_152

        before_validation { |<<model>>| <<model>>.validate_<<field>>_upload }
        before_save { |<<model>>| <<model>>.store_<<field>>_upload }
        after_save { |<<model>>| <<model>>.delete_replaced_<<field>> }
        after_destroy { |<<model>>| <<model>>.purge_<<field>> }

        # Takes the Cybertrain::UploadedFile of a form (params.nested(:<<model>>).upload(:<<field>>)),
        # or nil. Nil or an empty file keeps the current one.
        def <<field>>_file=(upload)
          @<<field>>_upload = upload.nil? ? Cybertrain::UploadedFile.blank : upload
        end

        def <<field>>_attached?
          !<<field>>_key.to_s.empty?
        end

        # Where the file is served from (the download action of the
        # controller); "" when none is attached. ?v= changes with the content,
        # so a replaced file is not served from a browser's cache.
        def <<field>>_url
          <<field>>_attached? ? "/<<plural>>/#{id}/<<field>>?v=#{<<field>>_checksum.to_s[0, 12]}" : ""
        end

        # Public so the callbacks above (which receive the record) can call them.

        def validate_<<field>>_upload
          pending = <<field>>_pending_upload
          return nil if pending.empty?

          errors.add(:<<field>>, "is too large (maximum is 2 MB)") if pending.byte_size > <<FIELD>>_MAX_BYTES
        <<type_check>>  nil
        end

        # Writes the new file to disk under a random key and points the columns
        # at it. The old key is kept for delete_replaced_<<field>>. A save that fails
        # after this point (a database error) leaves the new blob orphaned.
        def store_<<field>>_upload
          pending = <<field>>_pending_upload
          return nil if pending.empty?

          key = Cybertrain::BlobStore.new_key
          Cybertrain::BlobStore.write(key, pending.body_bytes)
          @replaced_<<field>>_key = <<field>>_key.to_s
          self.<<field>>_key = key
          self.<<field>>_filename = pending.original_filename
          self.<<field>>_content_type = pending.detected_content_type
          self.<<field>>_byte_size = pending.byte_size
          self.<<field>>_checksum = pending.sha256_hex
          @<<field>>_upload = Cybertrain::UploadedFile.blank
          nil
        end

        def delete_replaced_<<field>>
          old = @replaced_<<field>>_key
          old = "" if old.nil?
          Cybertrain::BlobStore.delete(old) unless old.empty?
          @replaced_<<field>>_key = ""
          nil
        end

        def purge_<<field>>
          Cybertrain::BlobStore.delete(<<field>>_key.to_s)
          nil
        end

        def <<field>>_pending_upload
          upload = @<<field>>_upload
          upload.nil? ? Cybertrain::UploadedFile.blank : upload
        end
      RUBY

      TYPE_CHECK_LINE = "  errors.add(:<<field>>, \"must be a PNG, JPEG, GIF or WebP image\") unless <<FIELD>>_TYPES.empty? || <<FIELD>>_TYPES.include?(pending.detected_content_type)\n"

      # Inserted (indented) after the controller's class line. `scoped`: the
      # record comes from `before_action :set_<model>`; otherwise the action
      # looks it up itself.
      def self.action_block(spec, scoped)
        text = ACTION_BLOCK.sub("<<lookup_note>>", scoped ? LOOKUP_SCOPED_NOTE : LOOKUP_FIND_NOTE)
        text = text.sub("<<lookup>>", scoped ? "" : "  @<<model>> = <<Model>>.find(params[:id])\n")
        spec.expand(text)
      end

      LOOKUP_SCOPED_NOTE = <<~'RUBY'
        # GET /<<plural>>/1/<<field>> -- @<<model>> comes from before_action :set_<<model>>, so
        # the download is scoped exactly like show (and authentication applies).
      RUBY

      LOOKUP_FIND_NOTE = <<~'RUBY'
        # GET /<<plural>>/1/<<field>> -- runs after this controller's before_actions
        # (authentication applies), but the lookup below is unscoped: if your other
        # actions limit which records a user may see, limit this one the same way.
      RUBY

      ACTION_BLOCK = <<~'RUBY'
        <<lookup_note>># send_blob is the one way to serve uploads: it sets the type from what the
        # server detected, nosniff, a locked-down CSP and Content-Disposition
        # (inline for images only, a download otherwise).
        def <<field>>
        <<lookup>>  if @<<model>>.<<field>>_attached? && Cybertrain::BlobStore.exist?(@<<model>>.<<field>>_key)
            send_blob(Cybertrain::BlobStore.read(@<<model>>.<<field>>_key), filename: @<<model>>.<<field>>_filename, content_type: @<<model>>.<<field>>_content_type)
          else
            head 404
          end
        end

      RUBY

      # ---- the generated test ---------------------------------------------

      # The app test for this attachment: written as test/attachment_post_cover.rb.
      # It signs in first when the app has authentication (app/models/user.rb;
      # a later `generate authentication` adds the sign-in to it instead),
      # fills the form fields the model validates for presence, and checks
      # the security-relevant behaviour (type, filename, CSRF, cleanup).
      def self.attachment_test(root, spec)
        auth = File.exist?(File.join(root, "app/models/user.rb"))
        text = TEST_HEAD
        text += spec.any ? TEST_PNG_ROUNDTRIP + TEST_ANY_TYPE : TEST_PNG_ROUNDTRIP + TEST_REJECT_TYPES
        text += TEST_COMMON
        fields = required_fields(root, spec)
        text += TEST_KEEP
        if auth
          open_download = download_access(File.read(File.join(root, controller_file(spec))), spec) == "public"
          text += open_download ? TEST_PUBLIC_DOWNLOAD : TEST_AUTH_DOWNLOAD
        end
        text += TEST_TAIL
        text = text.sub("  <<reset_auth>>\n", auth ? Authentication::TEST_RESET_LINES : "")
        text = text.sub("  <<sign_in>>\n", auth ? Authentication::TEST_SIGN_IN_LINES : "")
        text = text.sub("<<fields_lines>>", field_lines(root, spec, fields))
        text = text.sub("<<show_check>>", show_check(root, spec))
        spec.expand(text)
      end

      # The attributes the model validates for presence or a minimum length
      # (`validates :title, presence: true`), which a valid record needs in
      # the form.
      def self.required_fields(root, spec)
        names = Array.new(0) { "" }
        path = File.join(root, model_file(spec))
        return names unless File.exist?(path)

        File.read(path).each_line do |raw|
          line = raw.strip
          next unless line.start_with?("validates :") && (!line.index("presence: true").nil? || !line.index("minimum:").nil?)

          name = +""
          line[11, line.size - 11].to_s.each_char do |ch|
            break unless (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "_"

            name << ch
          end
          names << name unless name.empty? || names.include?(name)
        end
        names
      end

      def self.field_lines(root, spec, names)
        lines = +""
        names.each { |name| lines << "  fields[\"#{spec.singular}[#{name}]\"] = \"#{field_value(root, spec, name)}\"\n" }
        lines
      end

      # "A post", stretched to the field's `length: { minimum: N }` and cut
      # to its `maximum: N` (the blog's body needs 10 characters), so the
      # test's record is valid.
      def self.field_value(root, spec, name)
        value = "A #{spec.singular.tr("_", " ")}"
        min = length_bound(root, spec, name, "minimum:")
        max = length_bound(root, spec, name, "maximum:")
        value = value.ljust(min, ".") if min > value.size
        value = value[0, max].to_s if max >= 0 && value.size > max
        value
      end

      # The number after `key` (`minimum:`) on a `validates :name, ...` line
      # of the model, or -1.
      def self.length_bound(root, spec, name, key)
        bound = -1
        path = File.join(root, model_file(spec))
        return bound unless File.exist?(path)

        File.read(path).each_line do |raw|
          line = raw.strip
          next unless line.start_with?("validates :#{name},") || line == "validates :#{name}"

          at = line.index(key)
          next if at.nil?

          digits = +""
          line[at + key.size, line.size - at - key.size].to_s.strip.each_char do |ch|
            break unless ch >= "0" && ch <= "9"

            digits << ch
          end
          bound = digits.to_i unless digits.empty?
        end
        bound
      end

      # The show-page assertion, only when the show page renders the file
      # (the scaffold shape; another page may not).
      def self.show_check(root, spec)
        path = File.join(root, "app/views/#{spec.plural}/show.html.erb")
        return "" unless File.exist?(path) && name_present?(File.read(path), "@#{spec.singular}.#{spec.field}_url")

        "  res = client.get(\"/#{spec.plural}/\#{record.id}\")\n  assert_includes res.body, \"/#{spec.plural}/\#{record.id}/#{spec.field}?v=\"\n"
      end

      TEST_HEAD = <<~'RUBY'
        # Uploads of <<Model>>#<<field>> through the full stack: the multipart parser, CSRF,
        # method override, the model's callbacks and the download action. Written
        # by `cybertrain generate attachment <<model>> <<field>>`. Run with
        # `cybertrain spin test`; its snapshot comes from the compiled binary (the
        # database is FFI): `script/regen-snapshot`-style, see README "Testing an app".
        require_relative "support/app_test"

        # Uploaded files land here, not in storage/uploads.
        Cybertrain::BlobStore.root = "tmp/test_uploads"

        # A PNG signature, then NUL, 0xFF and CR LF bytes: the server sniffs the
        # signature only, the rest shows that every byte survives the round trip.
        PNG_BYTES = Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x0D, 0x0A, 0x00, 0x01])
        HTML_BYTES = "<html><script>alert(document.cookie)</script></html>"
        SVG_BYTES = '<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"></svg>'

        # The text fields of the form besides the file, and the CSRF token. Add the
        # other attributes your <<Model>> requires.
        def <<model>>_fields(token)
          fields = { "authenticity_token" => token }
        <<fields_lines>>  fields
        end

        def new_client
          <<Model>>.all.delete_all
          <<reset_auth>>
          Dir.glob("tmp/test_uploads/*/*").each { |path| File.delete(path) }
          client = Cybertrain::Test::Client.new(APP)
          <<sign_in>>
          client
        end

        # POST /<<plural>> with one file in <<model>>[<<field>>], as the new form sends it.
        def create_<<model>>(client, filename, type, data)
          client.get("/<<plural>>/new")
          token = AppTest.form_token(client)
          field = "<<model>>[<<field>>]"
          upload = Cybertrain::Test::Upload.new(field, filename, type, data)
          client.post_multipart("/<<plural>>", <<model>>_fields(token), [upload])
        end

      RUBY

      TEST_PNG_ROUNDTRIP = <<~'RUBY'
        test "a PNG upload is stored on disk and served back with safe headers" do
          client = new_client
          res = create_<<model>>(client, "<<field>>.png", "image/png", PNG_BYTES)
          assert_response res, :see_other
          assert_equal 1, <<Model>>.count
          record = <<Model>>.first
          assert record.<<field>>_attached?
          assert_equal "<<field>>.png", record.<<field>>_filename
          assert_equal "image/png", record.<<field>>_content_type
          assert_equal PNG_BYTES.bytesize, record.<<field>>_byte_size
          assert Cybertrain::BlobStore.exist?(record.<<field>>_key)
          res = client.get("/<<plural>>/#{record.id}/<<field>>")
          assert_response res, :ok
          served = res.body
          assert_equal PNG_BYTES.bytesize, served.bytesize
          name = "copy.png"
          data = served.b
          copy = Cybertrain::UploadedFile.new(name, "", data)
          assert_equal record.<<field>>_checksum, copy.sha256_hex
          assert res.header("content-type").to_s.start_with?("image/png"), "content-type"
          assert_equal "nosniff", res.header("x-content-type-options")
          assert res.header("content-disposition").to_s.start_with?("inline"), "content-disposition"
          assert_equal "default-src 'none'; sandbox", res.header("content-security-policy")
        <<show_check>>end

      RUBY

      TEST_REJECT_TYPES = <<~'RUBY'
        test "HTML and SVG bytes are refused even when named .png and declared image/png" do
          client = new_client
          res = create_<<model>>(client, "x.png", "image/png", HTML_BYTES)
          assert_response res, :unprocessable_entity
          assert_includes res.body, "<<Field>> must be a PNG, JPEG, GIF or WebP image"
          res = create_<<model>>(client, "logo.png", "image/png", SVG_BYTES)
          assert_response res, :unprocessable_entity
          assert_equal 0, <<Model>>.count
          assert_equal 0, Dir.glob("tmp/test_uploads/*/*").size
        end

      RUBY

      TEST_ANY_TYPE = <<~'RUBY'
        test "any file is accepted, stored as a download and never served inline" do
          client = new_client
          res = create_<<model>>(client, "page.html", "text/html", HTML_BYTES)
          assert_response res, :see_other
          record = <<Model>>.first
          assert_equal "application/octet-stream", record.<<field>>_content_type
          res = client.get("/<<plural>>/#{record.id}/<<field>>")
          assert_response res, :ok
          assert res.header("content-type").to_s.start_with?("application/octet-stream"), "content-type"
          assert res.header("content-disposition").to_s.start_with?("attachment"), "content-disposition"
          assert_equal "nosniff", res.header("x-content-type-options")
          assert_equal "default-src 'none'; sandbox", res.header("content-security-policy")
        end

      RUBY

      TEST_COMMON = <<~'RUBY'
        test "a file over the model's limit is a 422 with a message" do
          client = new_client
          big = +""
          big << PNG_BYTES
          big << ("a" * (<<Model>>::<<FIELD>>_MAX_BYTES + 1))
          res = create_<<model>>(client, "big.png", "image/png", big)
          assert_response res, :unprocessable_entity
          assert_includes res.body, "<<Field>> is too large (maximum is 2 MB)"
          assert_equal 0, <<Model>>.count
        end

        test "the client's filename is a display name: it never reaches the disk path" do
          client = new_client
          res = create_<<model>>(client, "../../evil.png", "image/png", PNG_BYTES)
          assert_response res, :see_other
          record = <<Model>>.first
          assert_equal "evil.png", record.<<field>>_filename
          key = record.<<field>>_key
          assert_equal 32, key.bytesize
          assert Cybertrain::BlobStore.valid_key?(key)
          path = Cybertrain::BlobStore.path_for(key)
          refute path.include?("evil"), path
          assert path.start_with?("tmp/test_uploads/"), path
          res = client.get("/<<plural>>/#{record.id}/<<field>>")
          assert_includes res.header("content-disposition").to_s, "filename=\"evil.png\""
        end

        test "replacing the file deletes the old blob; destroying the record deletes the current one" do
          client = new_client
          create_<<model>>(client, "one.png", "image/png", PNG_BYTES)
          record = <<Model>>.first
          old_key = record.<<field>>_key
          client.get("/<<plural>>/#{record.id}/edit")
          token = AppTest.form_token(client)
          field = "<<model>>[<<field>>]"
          upload = Cybertrain::Test::Upload.new(field, "two.png", "image/png", PNG_BYTES)
          res = client.patch_multipart("/<<plural>>/#{record.id}", <<model>>_fields(token), [upload])
          assert_response res, :see_other
          record = <<Model>>.find(record.id)
          new_key = record.<<field>>_key
          refute new_key == old_key, "the key changes with the file"
          assert_equal "two.png", record.<<field>>_filename
          refute Cybertrain::BlobStore.exist?(old_key), "the replaced blob is deleted"
          assert Cybertrain::BlobStore.exist?(new_key)
          client.get("/<<plural>>/#{record.id}")
          res = client.post("/<<plural>>/#{record.id}", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
          assert_response res, :see_other
          assert_equal 0, <<Model>>.count
          refute Cybertrain::BlobStore.exist?(new_key), "the destroyed record's blob is deleted"
        end

        test "a record whose blob is gone answers 404" do
          client = new_client
          create_<<model>>(client, "<<field>>.png", "image/png", PNG_BYTES)
          record = <<Model>>.first
          File.delete(Cybertrain::BlobStore.path_for(record.<<field>>_key))
          res = client.get("/<<plural>>/#{record.id}/<<field>>")
          assert_response res, :not_found
        end

        test "a multipart POST without the CSRF token is refused" do
          client = new_client
          client.get("/<<plural>>/new")
          field = "<<model>>[<<field>>]"
          upload = Cybertrain::Test::Upload.new(field, "<<field>>.png", "image/png", PNG_BYTES)
          fields = <<model>>_fields("unused")
          fields.delete("authenticity_token")
          res = client.post_multipart("/<<plural>>", fields, [upload])
          assert_response res, :forbidden
          assert_equal 0, <<Model>>.count
        end

      RUBY

      TEST_KEEP = <<~'RUBY'
        # What a browser sends for a file input left empty: filename="" and no
        # bytes. The parser drops it, so a form whose only field is the file
        # arrives without any <<model>>[...] key at all.
        test "an update without a file keeps the stored one" do
          client = new_client
          create_<<model>>(client, "<<field>>.png", "image/png", PNG_BYTES)
          record = <<Model>>.first
          key = record.<<field>>_key
          client.get("/<<plural>>/#{record.id}/edit")
          field = "<<model>>[<<field>>]"
          empty = Cybertrain::Test::Upload.new(field, "", "application/octet-stream", "")
          res = client.patch_multipart("/<<plural>>/#{record.id}", <<model>>_fields(AppTest.form_token(client)), [empty])
          assert_response res, :see_other
          record = <<Model>>.find(record.id)
          assert_equal key, record.<<field>>_key
          assert Cybertrain::BlobStore.exist?(key)
        end

      RUBY

      TEST_AUTH_DOWNLOAD = <<~'RUBY'
        test "the download needs a signed-in user, like every other action of the controller" do
          client = new_client
          create_<<model>>(client, "<<field>>.png", "image/png", PNG_BYTES)
          record = <<Model>>.first
          anonymous = Cybertrain::Test::Client.new(APP)
          res = anonymous.get("/<<plural>>/#{record.id}/<<field>>")
          assert_redirected_to res, "/session/new"
        end

      RUBY

      TEST_PUBLIC_DOWNLOAD = <<~'RUBY'
        test "the download is public like show: a visitor gets the file" do
          client = new_client
          create_<<model>>(client, "<<field>>.png", "image/png", PNG_BYTES)
          record = <<Model>>.first
          anonymous = Cybertrain::Test::Client.new(APP)
          res = anonymous.get("/<<plural>>/#{record.id}/<<field>>")
          assert_response res, :ok
          assert_equal PNG_BYTES.bytesize, res.body.bytesize
        end

      RUBY

      TEST_TAIL = <<~'RUBY'
        Cybertrain::Test.run!
      RUBY
    end
  end
end
