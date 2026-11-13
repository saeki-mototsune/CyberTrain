# Gen::TestDataEmitter -- gen/test/data.rb (spec sections 6 and 7, plan
# decision D8): what `cybertrain test` clears and loads before each test.
#
# - Gen::TestData::TABLES, every table of db/schema.rb (the clear's list);
# - FIXTURE_SQL, one `INSERT INTO "<table>" (...) VALUES (...)` per fixture
#   row (Gen::FixtureScan), and FIXTURE_TIMESTAMPS, how many `?` each
#   statement binds to the Clock's time (its filled created_at / updated_at);
# - per fixture file, LABELS_<table> and IDS_<table>, parallel;
# - Gen::TestFixtures.<table>(label), answering `<Model>.find(<label's id>)`
#   and raising Cybertrain::Test::FixtureNotFound for an unknown label,
#   with one-line forwarders as instance methods of ActiveSupport::TestCase
#   (the class form) and at the top level (the top-level form).
#
# The file never carries TestScan's copy footer: gen's sweep of gen/test/
# removes only files that do, and leaves this one to the Runner.
require "cybertrain/generator/fixture_scan"
require "cybertrain/generator/model_naming"
require "cybertrain/generator/models_emitter"

module Cybertrain
  module Gen
    module TestDataEmitter
      HEADER = "# gen/test/data.rb, written by `spin run gen` from db/schema.rb and\n" \
               "# test/fixtures/*.yml. Do not edit: the tables `cybertrain test` clears\n" \
               "# before each test, the fixtures it then inserts, and their accessors.\n".freeze

      # gen/test/data.rb's source for the schema's tables and the rows.
      def self.emit(schema, rows)
        src = +HEADER
        src << "require \"cybertrain/test/test_case\"\n"
        src << "require \"cybertrain/test/database\"\n\n"
        src << "module Gen\n"
        src << "  module TestData\n"
        names = Array.new(0) { "" }
        schema.tables.each { |t| names << t.name }
        src << "    TABLES = #{TestDataEmitter.string_array(names, "    ")}.freeze\n"
        sql = Array.new(0) { "" }
        counts = Array.new(0) { "" }
        rows.each do |r|
          sql << TestDataEmitter.insert_sql(r)
          counts << r.row_timestamps.size.to_s
        end
        src << "    FIXTURE_SQL = #{TestDataEmitter.string_array(sql, "    ")}.freeze\n"
        src << "    FIXTURE_TIMESTAMPS = #{TestDataEmitter.integer_array(counts)}.freeze\n"
        sets = TestDataEmitter.fixture_sets(rows)
        sets.each do |set|
          labels = Array.new(0) { "" }
          ids = Array.new(0) { "" }
          rows.each do |r|
            next unless r.row_table == set

            labels << r.row_label
            ids << r.row_id.to_s
          end
          src << "    LABELS_#{set} = [#{labels.map { |l| ModelsEmitter.ruby_string(l) }.join(", ")}].freeze\n"
          src << "    IDS_#{set} = #{TestDataEmitter.integer_array(ids)}.freeze\n"
        end
        src << "  end\n\n"
        src << "  # One accessor per fixture file: posts(:one) is Post.find(one's id).\n"
        src << "  module TestFixtures\n"
        sets.each do |set|
          model = ModelNaming.model_class_name(set)
          src << "    def self.#{set}(label) = #{model}.find(Cybertrain::Test.fixture_id(#{ModelsEmitter.ruby_string(set)}, label, " \
                 "TestData::LABELS_#{set}, TestData::IDS_#{set}))\n"
        end
        src << "  end\n"
        src << "end\n\n"
        src << "# The accessors in a class-form test.\n"
        src << "class ActiveSupport::TestCase\n"
        sets.each { |set| src << "  def #{set}(label) = Gen::TestFixtures.#{set}(label)\n" }
        src << "end\n\n"
        src << "# The accessors in a top-level-form test.\n"
        sets.each { |set| src << "def #{set}(label) = Gen::TestFixtures.#{set}(label)\n" }
        src
      end

      # The row's INSERT statement.
      def self.insert_sql(row)
        columns = row.row_columns.map { |c| "\"#{c}\"" }.join(", ")
        "INSERT INTO \"#{row.row_table}\" (#{columns}) VALUES (#{row.row_values.join(", ")})"
      end

      # The tables that have an accessor (an id column and at least one
      # row), in the rows' order.
      def self.fixture_sets(rows)
        sets = Array.new(0) { "" }
        rows.each { |r| sets << r.row_table if r.row_id >= 0 && !sets.include?(r.row_table) }
        sets
      end

      # A Ruby Array literal of Strings, one per line once it has any.
      def self.string_array(items, indent)
        return "Array.new(0) { \"\" }" if items.empty?

        out = +"[\n"
        items.each_with_index do |item, i|
          out << "#{indent}  #{ModelsEmitter.ruby_string(item)}"
          out << (i + 1 < items.size ? ",\n" : "\n")
        end
        out << "#{indent}]"
        out
      end

      # A Ruby Array literal of the Integers written in `items`.
      def self.integer_array(items)
        return "Array.new(0) { 0 }" if items.empty?

        "[#{items.join(", ")}]"
      end
    end
  end
end
