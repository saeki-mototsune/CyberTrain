# `cybertrain generate scaffold post title:string body:text`: writes the
# migration, model, controller and views of a resource and adds
# `resources :posts` to config/routes.rb, the way Rails' scaffold does.
require "cybertrain/generator/inflector"
require "cybertrain/ident"
require "cybertrain/cli/templates"

module Cybertrain
  module CLI
    class InvalidArgument < StandardError
    end

    # One "name:type" argument. A references field ("post:references")
    # becomes the post_id column.
    class Field
      TYPES = %w[string text integer float boolean date datetime references]

      # Columns every table already has (the primary key and t.timestamps).
      # Everything else a column may not be called -- Ruby keywords, names
      # that collide with the generated model -- comes from Cybertrain::Ident,
      # the same rules the generator applies, so the scaffold refuses the
      # name instead of writing files that `spin run gen` then rejects.
      RESERVED_COLUMNS = %w[id created_at updated_at]

      attr_reader :field_name, :field_type

      def self.parse(arg)
        colons = 0
        arg.each_char { |ch| colons += 1 if ch == ":" }
        raise InvalidArgument, "bad field '#{arg}': use name:type (modifiers such as :index are not supported)" if colons > 1

        parts = arg.split(":")
        name = parts[0].to_s
        type = parts.size > 1 ? parts[1].to_s : "string"
        type = "references" if type == "belongs_to"
        raise InvalidArgument, "bad field name '#{name}'" unless Templates.identifier?(name)
        raise InvalidArgument, "'#{name}' is a Ruby keyword and cannot name a field" if Ident.keyword?(name)
        raise InvalidArgument, "unknown type '#{type}' for #{name} (use #{TYPES.join(", ")})" unless TYPES.include?(type)

        field = Field.new(name, type)
        raise InvalidArgument, "'#{field.column_name}' is a column every table already has" if RESERVED_COLUMNS.include?(field.column_name)
        if Ident.reserved_column?(field.column_name)
          raise InvalidArgument, "'#{field.column_name}' would shadow a method of the generated model (Cybertrain::Model); pick another name"
        end
        # A references field also defines the reader `def <name>` (post:references
        # -> def post), which answers to the same rules as a column.
        if field.reference? && Ident.reserved_column?(name)
          raise InvalidArgument, "'#{name}' would shadow a method of the generated model (Cybertrain::Model); pick another name for the reference"
        end

        field
      end

      def initialize(field_name, field_type)
        @field_name = field_name
        @field_type = field_type
      end

      def reference?
        @field_type == "references"
      end

      def column_name
        reference? ? "#{@field_name}_id" : @field_name
      end

      def label
        Templates.humanize(@field_name)
      end

      def migration_line
        reference? ? "t.references :#{@field_name}" : "t.#{@field_type} \"#{@field_name}\""
      end

      # The FormBuilder method that edits this column.
      def form_input
        case @field_type
        when "text" then "text_area"
        when "integer", "float" then "number_field"
        when "boolean" then "check_box"
        else "text_field"
        end
      end
    end

    # The names a scaffold derives from its NAME argument ("post", "Post"
    # or "posts" all give post / posts / Post / Posts).
    class Resource
      attr_reader :singular, :plural, :class_name, :plural_class, :fields

      def initialize(name, fields)
        @singular = Inflector.singularize(Inflector.underscore(name))
        @plural = Inflector.pluralize(@singular)
        @class_name = Inflector.camelize(@singular)
        @plural_class = Inflector.camelize(@plural)
        @fields = fields
      end

      # The index route helper's name without _path, as Rails' scaffold
      # names it: the plural, or "<plural>_index" for a word that is its own
      # plural (sheep_index_path), matching the routes DSL.
      def index_helper
        @plural == @singular ? "#{@plural}_index" : @plural
      end

      # The column the model validates for presence ("" when there is none).
      def first_string_field
        @fields.each { |f| return f.field_name if f.field_type == "string" }
        ""
      end
    end

    module Scaffold
      DRAW_LINE = "Cybertrain::Routes.draw do"

      # Returns the paths it created (files that already exist are reported
      # as "identical" or "exist" and left alone). Raises InvalidArgument on a
      # bad name, a bad or duplicate field, or a routes file without a
      # `Cybertrain::Routes.draw do` line, before anything is written.
      def self.generate(root, name, fields)
        routes_path = File.join(root, "config/routes.rb")
        raise InvalidArgument, "#{routes_path} not found: run this inside a cybertrain app" unless File.exist?(routes_path)
        raise InvalidArgument, "#{routes_path} has no `#{DRAW_LINE}` line" if File.read(routes_path).index(DRAW_LINE).nil?

        underscored = Inflector.underscore(name)
        raise InvalidArgument, "bad resource name '#{name}'" unless Templates.identifier?(underscored)
        singular = Inflector.singularize(underscored)
        raise InvalidArgument, "'#{name}' is a Ruby keyword and cannot name a resource" if Ident.keyword?(singular)
        # The singular becomes the belongs_to reader on every model that
        # references this one (`hash:references` -> def hash), which the
        # generator would refuse too. The plural (the has_many side) is left
        # to the generator, which renames such a reader (`errors_as_post`)
        # rather than refusing it -- and nothing may reference the table.
        if Ident.reserved_column?(singular)
          raise InvalidArgument, "'#{name}' would be read as `#{singular}` on the models that reference it, " \
                                 "shadowing a method of the generated model (Cybertrain::Model); pick another name"
        end

        parsed = Array.new(0) { Field.new("", "") }
        columns = Array.new(0) { "" }
        fields.each do |arg|
          field = Field.parse(arg)
          raise InvalidArgument, "duplicate column '#{field.column_name}'" if columns.include?(field.column_name)

          columns << field.column_name
          parsed << field
        end
        res = Resource.new(name, parsed)

        created = Array.new(0) { "" }
        migration = migration_path(root, res)
        record(created, root, migration, Templates.migration(res))
        record(created, root, "app/models/#{res.singular}.rb", Templates.model(res))
        record(created, root, "app/controllers/#{res.plural}_controller.rb", Templates.controller(res))
        views = "app/views/#{res.plural}"
        record(created, root, "#{views}/index.html.erb", Templates.index_view(res))
        record(created, root, "#{views}/show.html.erb", Templates.show_view(res))
        record(created, root, "#{views}/new.html.erb", Templates.new_view(res))
        record(created, root, "#{views}/edit.html.erb", Templates.edit_view(res))
        record(created, root, "#{views}/_form.html.erb", Templates.form_partial(res))
        add_route(routes_path, res.plural)
        created
      end

      def self.record(created, root, path, content)
        created << path if Templates.write(root, path, content) == "create"
        nil
      end

      # db/migrate/<timestamp>_create_posts.rb, or the existing
      # *_create_posts.rb when the scaffold already ran.
      def self.migration_path(root, res)
        suffix = "_create_#{res.plural}.rb"
        existing = Dir.glob(File.join(root, "db/migrate/*#{suffix}")).sort
        return "db/migrate/#{File.basename(existing[0])}" unless existing.empty?

        "db/migrate/#{next_version(root, timestamp)}#{suffix}"
      end

      # The version a new migration gets: stamp, unless db/migrate already
      # holds a version >= stamp (two scaffolds in the same second, or a
      # fixed CYBERTRAIN_TIMESTAMP), in which case the largest one + 1, the
      # way Rails does it. Versions must stay unique (schema_migrations keys
      # on them) and increasing (they order the migrations).
      def self.next_version(root, stamp)
        largest = 0
        Dir.glob(File.join(root, "db/migrate/*.rb")).each do |path|
          digits = leading_digits(File.basename(path))
          next if digits == ""

          v = digits.to_i
          largest = v if v > largest
        end
        return stamp if stamp.to_i > largest

        (largest + 1).to_s
      end

      def self.leading_digits(name)
        out = +""
        name.each_char do |ch|
          break unless ch >= "0" && ch <= "9"

          out << ch
        end
        out
      end

      def self.timestamp
        fixed = ENV["CYBERTRAIN_TIMESTAMP"]
        return fixed.to_s unless fixed.nil? || fixed == ""

        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end

      # Inserts `  resources :posts` right after `Cybertrain::Routes.draw do`
      # unless a `resources :posts` line is already there.
      def self.add_route(routes_path, plural)
        route = "resources :#{plural}"
        source = File.read(routes_path)
        lines = source.split("\n")
        present = false
        lines.each do |line|
          l = line.strip
          present = true if l == route || l.start_with?("#{route} ") || l.start_with?("#{route},")
        end
        if present
          puts "identical route #{route}"
          return false
        end

        at = source.index(DRAW_LINE)
        raise InvalidArgument, "#{routes_path} has no `#{DRAW_LINE}` line" if at.nil?

        eol = source.index("\n", at)
        eol = source.size if eol.nil?
        updated = +""
        updated << source[0, eol]
        updated << "\n  #{route}"
        updated << source[eol, source.size - eol]
        updated << "\n" unless updated.end_with?("\n")
        File.write(routes_path, updated)
        puts "route #{route}"
        true
      end
    end
  end
end
