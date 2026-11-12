# Gen::FixtureScan -- reads test/fixtures/*.yml at build time (spec section
# 7, plan decision D8) into one FixtureRow per label: the table, Rails' id
# for the label (or its `id:`), and the INSERT's columns and SQL literals.
#
#   rows = Gen::FixtureScan.scan(root, Cybertrain::Schema.current, ModelScan.scan_dir("#{root}/app/models"))
#
# A file is `test/fixtures/<table>.yml` (subdirectories, such as Rails'
# test/fixtures/files, are not fixtures), read with Gen::LocaleYaml (its
# refusals apply, with file and line) with labels at the top and one level
# of columns under each. A key is a column of the table or a `belongs_to`
# of the table's model, whose value is the parent's label (`post: one` sets
# post_id to one's id, as Rails does; the label is not checked against the
# other file). Values are converted by the column's type: strings, text,
# json and binary as written, integers, floats and decimals as numbers,
# booleans true / false as 1 / 0, dates as YYYY-MM-DD and datetimes read
# as UTC into Cast.sql_datetime's text; `~`, `null` and an empty value are
# NULL. A table's created_at / updated_at that a row leaves out are bound
# at insert to the Clock's time (row_timestamps, each a `?`).
#
# Refused, as ArgumentError "<path>:<line>: problem": ERB (`<%` anywhere),
# a file that names no table of db/schema.rb, a key that is neither a
# column nor a belongs_to, two keys setting one column, two labels with
# one id, a nested mapping or a sequence under a label, a value its
# column's type cannot take, and a NUL byte.
#
# Spinel rules followed: 58 (each message is built into a local before
# raise), 62 (the file text is read through a fresh local), 9 (seeded
# containers), 10/34/41 (every method name here is new).
require "cybertrain/schema"
require "cybertrain/generator/inflector"
require "cybertrain/generator/crc32"
require "cybertrain/generator/locale_yaml"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/model_naming"

module Cybertrain
  module Gen
    # One fixture: an INSERT into row_table of row_values (SQL literals, a
    # `?` for each of row_timestamps) for row_columns ("id" first, then the
    # file's keys in order with a belongs_to as its foreign key, then the
    # filled timestamps). row_id is -1 for a table without an id column.
    # row_refs holds each belongs_to by label as "<parent table>\t<label>\t
    # <line>\t<association>", checked against the parent's file by scan.
    class FixtureRow
      attr_reader :row_table, :row_label, :row_id, :row_columns, :row_values, :row_line, :row_timestamps, :row_refs

      def initialize(table, label, id, columns, values, line, timestamps, refs)
        @row_table = table
        @row_label = label
        @row_id = id
        @row_columns = columns
        @row_values = values
        @row_line = line
        @row_timestamps = timestamps
        @row_refs = refs
      end
    end

    module FixtureScan
      ERB_REFUSAL = "ERB is not supported in fixtures (there is no eval); set the value in setup or use travel_to".freeze
      NESTED_REFUSAL = "fixtures hold one level of columns under each label".freeze
      TIMESTAMPS = %w[created_at updated_at].freeze
      # Rails' label for a fixture file's shared values: never a row.
      DEFAULTS_LABEL = "DEFAULTS".freeze
      # Top-level methods an accessor `def <table>(label)` would replace:
      # the test harness's (cybertrain/test.rb, cybertrain/test/*.rb) and
      # Kernel's.
      TAKEN_NAMES = %w[assert assert_changes assert_difference assert_empty assert_enqueued_jobs assert_enqueued_with
                       assert_equal assert_in_delta assert_includes assert_match assert_nil assert_no_difference
                       assert_no_enqueued_jobs assert_no_match assert_not assert_not_empty assert_not_equal
                       assert_not_includes assert_not_nil assert_nothing_raised assert_raises assert_redirected_to
                       assert_response clear_enqueued_jobs flunk freeze_time perform_enqueued_jobs refute setup teardown
                       test travel travel_back travel_to abort at_exit binding caller catch exit fail fork format
                       gets lambda load loop open p print printf proc putc puts raise rand readline readlines require
                       require_relative select sleep spawn sprintf srand system throw trap warn].freeze
      INT64_MAX = "9223372036854775807".freeze
      INT64_MIN = "9223372036854775808".freeze

      # Every row of root/test/fixtures/*.yml, the files in name order and
      # each file's labels in file order.
      def self.scan(root, schema, model_infos)
        rows = Array.new(0) { FixtureScan.empty_row }
        dir = "#{root}/test/fixtures"
        return rows unless File.directory?(dir)

        names = Dir.children(dir).select { |n| n.end_with?(".yml") && File.file?("#{dir}/#{n}") }.sort
        names.each do |name|
          FixtureScan.scan_file(root, name, schema, model_infos).each { |r| rows << r }
        end
        tables = names.map { |n| n.delete_suffix(".yml") }
        rows.each { |r| r.row_refs.each { |ref| FixtureScan.check_ref(r, ref, tables, rows) } }
        rows
      end

      # A belongs_to label checked against the parent's file, when there is
      # one: the label must be there, and its id must be the label's CRC
      # (Rails' rule; an explicit `id:` is not what the label stands for).
      # Without the parent's file the database's foreign-key check at load
      # time reports it (Test::Database).
      def self.check_ref(row, ref, tables, rows)
        parts = ref.split("\t")
        parent = parts[0].to_s
        label = parts[1].to_s
        line = parts[2].to_i
        name = parts[3].to_s
        return nil unless tables.include?(parent)

        path = "test/fixtures/#{row.row_table}.yml"
        found = FixtureScan.empty_row
        hit = false
        rows.each do |r|
          next unless r.row_table == parent && r.row_label == label

          found = r
          hit = true
        end
        FixtureScan.refuse_fixture(path, line, "#{row.row_table}: #{name} #{label.inspect} names no label of test/fixtures/#{parent}.yml") unless hit
        id = Crc32.fixture_id(label)
        unless found.row_id == id
          message = "#{row.row_table}: #{name} #{label.inspect} stands for id #{id} (Rails' id for the label), but that label has " \
                    "id: #{found.row_id} in test/fixtures/#{parent}.yml; write #{name}_id: #{found.row_id}"
          FixtureScan.refuse_fixture(path, line, message)
        end
        nil
      end

      # Refuses a fixture file whose accessor (`def <table>(label)` at the
      # top level and in ActiveSupport::TestCase) would replace a method of
      # the harness, of Kernel, or a top-level def of the app's test files
      # (TestScan.scan's test_helpers).
      def self.refuse_accessor_clashes(rows, files)
        seen = Array.new(0) { "" }
        rows.each do |r|
          set = r.row_table
          next if seen.include?(set) || r.row_id < 0

          seen << set
          path = "test/fixtures/#{set}.yml"
          if TAKEN_NAMES.include?(set)
            FixtureScan.refuse_fixture(path, 1, "the fixture accessor #{set}(label) would replace the top-level #{set} of the test harness or Kernel")
          end
          files.each do |f|
            f.test_helpers.each do |h|
              next unless h.helper_kind == "def" && h.helper_name == set

              FixtureScan.refuse_fixture(path, 1, "the fixture accessor #{set}(label) would replace the top-level def #{set} at " \
                                                  "#{f.test_path}:#{h.helper_line}; rename that helper")
            end
          end
        end
        nil
      end

      def self.empty_row
        FixtureRow.new("", "", 0, Array.new(0) { "" }, Array.new(0) { "" }, 0, Array.new(0) { "" }, Array.new(0) { "" })
      end

      # The rows of test/fixtures/<name>.
      def self.scan_file(root, name, schema, model_infos)
        path = "test/fixtures/#{name}"
        raw = File.read("#{root}/#{path}")
        text = raw.to_s
        erb = text.index("<%")
        FixtureScan.refuse_fixture(path, FixtureScan.line_at(text, erb.to_i), ERB_REFUSAL) unless erb.nil?
        table_name = name.delete_suffix(".yml")
        table = schema.table(table_name)
        FixtureScan.refuse_fixture(path, 1, "no table named #{table_name.inspect} in db/schema.rb") if table.nil?

        mappings = { "" => 0 }
        mappings.delete("")
        entries = LocaleYaml.parse_recording(text, path, mappings, false)
        info = FixtureScan.model_info(table_name, model_infos)
        rows = Array.new(0) { FixtureScan.empty_row }
        label = ""
        label_line = 0
        keys = Array.new(0) { LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) }
        entries.each do |entry|
          key = entry.entry_key
          dot = key.index(".")
          if dot.nil?
            # A label with nothing under it: a row of defaults.
            FixtureScan.refuse_fixture(path, entry.entry_line, NESTED_REFUSAL) if entry.entry_is_list || !entry.entry_null
            rows << FixtureScan.build_row(path, table, info, label, label_line, keys) unless label.empty?
            label = key
            label_line = entry.entry_line
            keys = Array.new(0) { LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) }
            next
          end
          owner = key[0, dot].to_s
          column = key[dot + 1, key.size - dot - 1].to_s
          FixtureScan.refuse_fixture(path, entry.entry_line, NESTED_REFUSAL) if entry.entry_is_list || column.include?(".")
          if owner != label
            rows << FixtureScan.build_row(path, table, info, label, label_line, keys) unless label.empty?
            label = owner
            label_line = mappings.key?(owner) ? mappings[owner] : entry.entry_line
            keys = Array.new(0) { LocaleEntry.new("", "", Array.new(0) { "" }, false, "", 0) }
          end
          keys << LocaleEntry.new(column, entry.entry_text, Array.new(0) { "" }, false, path, entry.entry_line, entry.entry_null)
        end
        rows << FixtureScan.build_row(path, table, info, label, label_line, keys) unless label.empty?
        # DEFAULTS is checked like any label but never inserted: Rails
        # deletes it (it only carries anchors, which this reader refuses).
        kept = Array.new(0) { FixtureScan.empty_row }
        rows.each { |r| kept << r unless r.row_label == DEFAULTS_LABEL }
        FixtureScan.refuse_same_ids(path, table_name, kept)
        kept
      end

      # One label's row from its keys (each a LocaleEntry whose entry_key
      # is the column as written).
      def self.build_row(path, table, info, label, line, keys)
        columns = Array.new(0) { "" }
        values = Array.new(0) { "" }
        refs = Array.new(0) { "" }
        id = 0
        given = false
        keys.each do |k|
          name = k.entry_key
          target = name
          literal = "NULL"
          if name == "id" && !table.without_id?
            unless k.entry_null
              positive = FixtureScan.int64_text?(k.entry_text) && !k.entry_text.start_with?("-") && k.entry_text.to_i > 0
              FixtureScan.refuse_type(path, k, table.name, "a positive integer") unless positive
              id = k.entry_text.to_i
              given = true
            end
            next
          end
          column = table.column(name)
          if column.nil?
            association = FixtureScan.belongs_to_named(info, name)
            if association.nil?
              FixtureScan.refuse_fixture(path, k.entry_line, "#{table.name} has no column or belongs_to named #{name.inspect}")
            else
              target = association.foreign_key.empty? ? "#{name}_id" : association.foreign_key
              unless k.entry_null
                literal = Crc32.fixture_id(k.entry_text).to_s
                model = association.class_name.empty? ? name : Inflector.underscore(association.class_name)
                refs << "#{Inflector.pluralize(model)}\t#{k.entry_text}\t#{k.entry_line}\t#{name}"
              end
            end
          else
            literal = FixtureScan.sql_literal(path, k, table.name, column.type) unless k.entry_null
          end
          if columns.include?(target)
            FixtureScan.refuse_fixture(path, k.entry_line, "#{table.name}: #{target} is set twice in #{label.inspect}")
          end
          columns << target
          values << literal
        end
        id = Crc32.fixture_id(label) unless given
        id = -1 if table.without_id?
        timestamps = Array.new(0) { "" }
        TIMESTAMPS.each do |t|
          next if table.column(t).nil? || columns.include?(t)

          columns << t
          values << "?"
          timestamps << t
        end
        unless table.without_id?
          columns.unshift("id")
          values.unshift(id.to_s)
        end
        FixtureRow.new(table.name, label, id, columns, values, line, timestamps, refs)
      end

      # Two labels of one file with one id, named at the second's line.
      def self.refuse_same_ids(path, table_name, rows)
        i = 0
        while i < rows.size
          j = 0
          while j < i
            if rows[i].row_id >= 0 && rows[i].row_id == rows[j].row_id
              message = "#{table_name}: labels #{rows[j].row_label.inspect} and #{rows[i].row_label.inspect} (line #{rows[j].row_line}) have the same id #{rows[i].row_id}"
              FixtureScan.refuse_fixture(path, rows[i].row_line, message)
            end
            j += 1
          end
          i += 1
        end
        nil
      end

      # The SQL literal for a value of a column of `type`.
      def self.sql_literal(path, key, table_name, type)
        text = key.entry_text
        if text.include?("\0")
          FixtureScan.refuse_fixture(path, key.entry_line, "a NUL byte is not allowed")
        end
        case type
        when :integer
          FixtureScan.refuse_type(path, key, table_name, "a 64-bit integer") unless FixtureScan.int64_text?(text)
          text.to_i.to_s
        when :float, :decimal
          FixtureScan.refuse_type(path, key, table_name, "a number") unless FixtureScan.number_text?(text)
          text
        when :boolean
          FixtureScan.refuse_type(path, key, table_name, "true or false") unless text == "true" || text == "false"
          text == "true" ? "1" : "0"
        when :date
          FixtureScan.refuse_type(path, key, table_name, "a date such as 2026-11-01") unless FixtureScan.date_text?(text)
          "'#{text}'"
        when :datetime
          stamp = FixtureScan.datetime_text(text)
          FixtureScan.refuse_type(path, key, table_name, "a UTC time such as 2026-11-01 09:00:00") if stamp.empty?
          "'#{stamp}'"
        else
          "'#{text.gsub("'", "''")}'"
        end
      end

      def self.refuse_type(path, key, table_name, what)
        FixtureScan.refuse_fixture(path, key.entry_line, "#{table_name}.#{key.entry_key} takes #{what} (got #{key.entry_text.inspect})")
      end

      def self.integer_text?(text) = text.match?(/\A[-+]?[0-9]+\z/)

      def self.number_text?(text) = text.match?(/\A[-+]?[0-9]+(\.[0-9]+)?\z/)

      # An integer that fits a signed 64-bit column (SQLite's INTEGER).
      def self.int64_text?(text)
        return false unless FixtureScan.integer_text?(text)

        negative = text.start_with?("-")
        body = text.delete_prefix("-").delete_prefix("+").sub(/\A0+/, "")
        return true if body.size < 19
        return false if body.size > 19

        body <= (negative ? INT64_MIN : INT64_MAX)
      end

      # YYYY-MM-DD naming a day of the calendar (2026-02-30 is not one).
      def self.date_text?(text)
        return false unless text.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)

        year = text[0, 4].to_i
        month = text[5, 2].to_i
        day = text[8, 2].to_i
        return false if month < 1 || month > 12 || day < 1

        days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        days = 29 if month == 2 && leap
        day <= days
      end

      # "2026-11-01 09:00:00" (also with T, without seconds, with a
      # fraction, with a trailing Z or UTC, or a bare date) as
      # "2026-11-01 09:00:00.000000"; "" when the text is none of those.
      def self.datetime_text(text)
        t = text.strip
        t = t.delete_suffix("UTC").strip if t.end_with?("UTC")
        t = t.delete_suffix("Z") if t.end_with?("Z")
        return "#{t} 00:00:00.000000" if FixtureScan.date_text?(t)
        return "" unless t.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?\z/)

        date = t[0, 10].to_s
        clock = t[11, t.size - 11].to_s
        hm = clock[0, 5].to_s
        seconds = clock.size >= 8 ? clock[6, 2].to_s : "00"
        return "" unless FixtureScan.date_text?(date) && hm[0, 2].to_i < 24 && hm[3, 2].to_i < 60 && seconds.to_i < 60
        fraction = clock.size > 9 ? clock[9, clock.size - 9].to_s : ""
        fraction = "#{fraction}000000"[0, 6].to_s
        "#{date} #{hm}:#{seconds}.#{fraction}"
      end

      # The ModelInfo of the table's model, or nil when app/models has none.
      def self.model_info(table_name, model_infos)
        class_name = ModelNaming.model_class_name(table_name)
        model_infos.each { |info| return info if info.class_name == class_name }
        nil
      end

      # The model's `belongs_to <name>`, or nil.
      def self.belongs_to_named(info, name)
        return nil if info.nil?

        info.associations.each { |a| return a if a.kind == :belongs_to && a.name == name }
        nil
      end

      # The 1-based line of character index `at` in text.
      def self.line_at(text, at)
        before = text[0, at].to_s
        before.count("\n") + 1
      end

      def self.refuse_fixture(path, line, problem)
        message = "#{path}:#{line}: #{problem}"
        raise ArgumentError, message
      end
    end
  end
end
