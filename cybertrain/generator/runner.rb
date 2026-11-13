require "cybertrain/generator/routes_dsl"
require "cybertrain/generator/routes_emitter"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/controllers_emitter"
require "cybertrain/generator/concern_scan"
require "cybertrain/generator/concerns_emitter"
require "cybertrain/generator/manifest"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/model_validation"
require "cybertrain/generator/models_emitter"
require "cybertrain/generator/migrations_emitter"
require "cybertrain/generator/views_emitter"
require "cybertrain/generator/helpers_emitter"
require "cybertrain/generator/components_emitter"
require "cybertrain/generator/console_emitter"
require "cybertrain/generator/jobs_emitter"
require "cybertrain/generator/assets_emitter"
require "cybertrain/generator/locale_scan"
require "cybertrain/generator/locales_emitter"
require "cybertrain/generator/test_scan"
require "cybertrain/generator/tests_emitter"
require "cybertrain/generator/test_data_emitter"

module Cybertrain
  module Gen
    # `spin run gen`: regenerates gen/ from the drawn routes and app/.
    # A file whose content would not change is left alone (its mtime too).
    # With --check nothing is written; each out-of-date file is reported as
    # "stale: <path>" and the exit code is 1.
    # `--embed-views` writes gen/views.rb with the app/views tree instead
    # of an empty table. gen/concerns/** holds one file per concern of
    # app/controllers and app/models (ConcernsEmitter.module_files); a file
    # there whose concern is gone is removed. A jobs page drawn without before_action: prints a
    # warning line first. gen/assets.rb holds the asset manifest and the
    # import map (AssetsEmitter); without --check the digested files are
    # also written to public/assets (AssetsEmitter.sync_public), which
    # --check never reads: it compares gen/assets.rb only. gen/locales.rb
    # holds config/locales/**/*.yml (LocaleScan, LocalesEmitter), written
    # with empty tables when the application has no dictionary.
    # gen/test/** holds the rewritten copy of each file of test/ that holds
    # a class-form test class (TestScan.copies: the helper and support
    # files included); a copy whose file is gone or no longer class form is
    # removed, as are the directories that leaves empty. Only gen's own
    # copies (their last line names the file they came from) are swept:
    # gen/test/data.rb, the fixtures' file, and anything else are left.
    # gen/test/data.rb itself (TestDataEmitter: the tables cleared before
    # each test, test/fixtures/*.yml's rows and accessors) is written from
    # the schema branch whenever test/ exists, and removed once it is gone.
    module Runner
      def self.run(root, argv)
        ControllerScan.use_root(root)
        check = argv.include?("--check")
        embed = argv.include?("--embed-views")
        jobs_page = Cybertrain::Routes.jobs_page_spec
        warning = ControllersEmitter.jobs_page_warning(jobs_page)
        puts warning unless warning.empty?
        views = ViewsEmitter.emit(root, embed)
        outputs = [
          ["gen/routes.rb", RoutesEmitter.emit(Cybertrain::Routes.specs)],
          # An embedded build's views go into its build digest (the ETags).
          ["gen/assets.rb", assets_output(root, check, embed ? views : "")],
          ["gen/locales.rb", Runner.locales_source(root)],
          ["gen/controllers.rb", controllers_source(root, jobs_page)],
          ["gen/concerns.rb", concerns_source(root)],
          ["gen/views.rb", views],
          ["gen/helpers.rb", HelpersEmitter.emit(HelperScan.scan_dir("#{root}/app/helpers"))],
          ["gen/components.rb", ComponentsEmitter.emit(ComponentScan.scan_dir("#{root}/app/components"))],
          ["gen/jobs.rb", JobsEmitter.emit(JobScan.scan_dir("#{root}/app/jobs"))]
        ]
        concern_files = Array.new(0) { "" }
        concern_modules(root).each do |rel, source|
          outputs << [rel, source]
          concern_files << rel
        end
        stale = 0
        test_copies = Array.new(0) { "" }
        TestScan.copies(root).each do |rel, source|
          outputs << [rel, source]
          test_copies << rel
        end
        # gen/tests.rb, the program `cybertrain test` compiles, whenever
        # test/ exists (a refused bundle is a program that only aborts with
        # the reason: gen itself still succeeds, pre-flight ruling B2).
        # With a loaded schema gen/test/data.rb is written too (below), and
        # the bundle requires it and clears and loads before every test. A
        # fixture gen cannot load refuses the bundle the same way: a
        # scaffold's test/fixtures/articles.yml comes before the migration
        # that creates its table, and `cybertrain db migrate` runs gen first.
        tests_rb = "#{root}/#{TestsEmitter::PATH}"
        fixture_problem = ""
        if File.directory?("#{root}/test")
          fixture_problem = Runner.fixture_problem(root) unless Cybertrain::Schema.current.nil?
          bundle = if fixture_problem.empty?
                     TestsEmitter.emit(root, TestScan.scan(root), !Cybertrain::Schema.current.nil?)
                   else
                     TestsEmitter.refused_program(fixture_problem)
                   end
          outputs << [TestsEmitter::PATH, bundle]
        elsif File.exist?(tests_rb) && File.read(tests_rb).start_with?(TestsEmitter::HEADER)
          stale += remove_file(root, TestsEmitter::PATH, check)
        end
        # gen/migrations.rb only once an app has a db/migrate directory (a
        # fixture or test tree with no db/ at all skips it entirely).
        outputs << ["gen/migrations.rb", MigrationsEmitter.emit(root)] if File.directory?("#{root}/db/migrate")
        # gen/models/<model>.rb per table once db/schema.rb has been loaded.
        schema = Cybertrain::Schema.current
        # A gen/concerns file whose concern is gone, and the directories
        # that leaves empty.
        Manifest.rb_files(root, "gen/concerns").each do |f|
          next if concern_files.include?(f + ".rb")

          stale += remove_file(root, f + ".rb", check)
          remove_empty_dirs(root, File.dirname(f), "gen/concerns") unless check
        end
        Manifest.rb_files(root, "gen/test").each do |f|
          next if test_copies.include?(f + ".rb") || f + ".rb" == TestScan::DATA_FILE
          next unless File.read("#{root}/#{f}.rb").include?("#{TestScan::FOOTER}test/")

          stale += remove_file(root, f + ".rb", check)
          remove_empty_dirs(root, File.dirname(f), "gen/test") unless check
        end
        if !File.directory?("#{root}/test") && File.exist?("#{root}/#{TestScan::DATA_FILE}")
          stale += remove_file(root, TestScan::DATA_FILE, check)
          remove_empty_dirs(root, "gen/test", "gen/test") unless check
        end
        if schema.nil?
          outputs << ["gen/console.rb", ConsoleEmitter.emit(Array.new(0) { "" })]
          outputs.each { |pair| stale += sync_file(root, pair[0], pair[1], check) }
          stale += sync_file(root, "gen/app.rb", Manifest.emit(root), check)
        else
          # Scan, then the semantic validation, then the emitter (D69): a
          # model that cannot be generated raises before anything is written.
          infos = ModelScan.scan_dir("#{root}/app/models")
          validated = ModelValidation.validate_all(schema, infos, SchemaPlaces.in_app(root))
          if File.directory?("#{root}/test")
            # No rows while the fixtures are refused (gen/tests.rb aborts).
            rows = fixture_problem.empty? ? FixtureScan.scan(root, schema, infos) : Array.new(0) { FixtureScan.empty_row }
            outputs << [TestScan::DATA_FILE, TestDataEmitter.emit(schema, rows)]
          end
          models = Array.new(0) { "" }
          ModelsEmitter.outputs_for(validated).each do |rel, source|
            outputs << [rel, source]
            models << rel.delete_suffix(".rb")
          end
          models = models.sort
          names = Array.new(0) { "" }
          ModelsEmitter.modelled_tables(schema).each { |t| names << ModelsEmitter.model_class_name(t.name) }
          schema.tables.each do |t|
            puts "skipped #{t.name}: no id column, so no model (reach it with Cybertrain::DB.with)" if t.without_id?
          end
          outputs << ["gen/console.rb", ConsoleEmitter.emit(names.sort)]
          outputs.each { |pair| stale += sync_file(root, pair[0], pair[1], check) }
          # A gen/models file whose table is gone from the schema.
          Manifest.rb_files(root, "gen/models").each do |f|
            stale += remove_file(root, f + ".rb", check) unless models.include?(f)
          end
          # The manifest lists the models the schema calls for, not the
          # files on disk, so --check reports it stale alongside them.
          stale += sync_file(root, "gen/app.rb", Manifest.emit_with_models(root, models), check)
        end
        stale > 0 ? 1 : 0
      end

      # Why test/fixtures/*.yml cannot be loaded, "<path>:<line>: ..." ("" when
      # they can): FixtureScan's refusals and its accessor clashes. The schema
      # is loaded (Schema.current).
      # @return [String]
      def self.fixture_problem(root)
        problem = ""
        begin
          rows = FixtureScan.scan(root, Cybertrain::Schema.current, ModelScan.scan_dir("#{root}/app/models"))
          FixtureScan.refuse_accessor_clashes(rows, TestScan.scan(root))
        rescue ArgumentError => e
          problem = e.message
        end
        problem
      end

      # gen/controllers.rb and gen/concerns.rb, each from its own scan of
      # app/controllers: with the two scans' results held in locals of run
      # and handed to both emitters, Spinel 2026.11.04.7026 warns that type
      # inference did not converge when it compiles bin/gen.rb. The app's
      # helper modules come too: a helper_method may not shadow one.
      def self.controllers_source(root, jobs_page)
        ControllerScan.use_root(root)
        ControllersEmitter.emit(ControllerScan.scan_dir("#{root}/app/controllers"), jobs_page, ConcernScan.scan_dir("#{root}/app/controllers"),
                                HelperScan.scan_dir("#{root}/app/helpers"))
      end

      def self.concerns_source(root)
        ControllerScan.use_root(root)
        ConcernsEmitter.emit(ControllerScan.scan_dir("#{root}/app/controllers"), ConcernScan.scan_dir("#{root}/app/controllers"),
                             ModelScan.scan_dir("#{root}/app/models"), ConcernScan.scan_dir("#{root}/app/models"))
      end

      # gen/assets.rb's source; without check, public/assets is brought up to
      # date first (its log lines printed). `views` is the embedded
      # gen/views.rb of an --embed-views run, "" otherwise.
      def self.assets_output(root, check, views)
        files = AssetScan.scan(root)
        AssetsEmitter.sync_public(root, files).each { |line| puts line } unless check
        AssetsEmitter.emit(files, importmap_pins(root, files), views)
      end

      # gen/locales.rb's source: root/config/locales merged.
      def self.locales_source(root)
        LocalesEmitter.emit(LocaleScan.scan(root), "Gen::Locales", true)
      end

      # gen/assets.rb's source, public/assets left alone.
      def self.assets_source(root)
        assets_output(root, true, "")
      end

      # The pins of root/config/importmap.rb (none without the file).
      def self.importmap_pins(root, files)
        path = "#{root}/#{ImportmapReader::PATH}"
        return Array.new(0) { ImportmapPin.new("", "", false) } unless File.exist?(path)

        ImportmapReader.read(File.read(path), files)
      end

      # gen/concerns/<path under app/> => source, for the concerns of
      # app/controllers then those of app/models.
      def self.concern_modules(root)
        ControllerScan.use_root(root)
        out = ConcernsEmitter.module_files(ConcernScan.scan_dir("#{root}/app/controllers"))
        ConcernsEmitter.module_files(ConcernScan.scan_dir("#{root}/app/models")).each { |rel, source| out[rel] = source }
        out
      end

      # Deletes a generated file that should no longer exist (with `check`,
      # reports it); returns 1 when stale.
      def self.remove_file(root, rel, check)
        if check
          puts "stale: #{rel}"
          1
        else
          File.delete("#{root}/#{rel}")
          puts "removed #{rel}"
          0
        end
      end

      # Removes root/rel and each parent of it that is left empty, up to
      # and including root/stop (gen/concerns goes too when no concern is
      # left).
      def self.remove_empty_dirs(root, rel, stop)
        dir = rel
        while dir == stop || dir.start_with?("#{stop}/")
          path = "#{root}/#{dir}"
          break unless File.directory?(path) && Dir.children(path).empty?

          Dir.rmdir(path)
          puts "removed #{dir}/"
          dir = File.dirname(dir)
        end
        nil
      end

      # Creates dir and any missing parent.
      def self.make_dirs(dir)
        return nil if File.directory?(dir)

        make_dirs(File.dirname(dir))
        Dir.mkdir(dir)
        nil
      end

      # Writes (or with `check`, compares) one generated file; returns 1 when stale.
      def self.sync_file(root, rel, source, check)
        path = "#{root}/#{rel}"
        current = File.exist?(path) ? File.read(path) : ""
        if current == source
          puts "identical #{rel}" unless check
          0
        elsif check
          puts "stale: #{rel}"
          1
        else
          make_dirs(File.dirname(path))
          File.write(path, source)
          puts "wrote #{rel}"
          0
        end
      end
    end
  end
end
