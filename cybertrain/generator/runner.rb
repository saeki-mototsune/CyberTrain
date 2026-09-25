require "cybertrain/generator/routes_dsl"
require "cybertrain/generator/routes_emitter"
require "cybertrain/generator/controller_scan"
require "cybertrain/generator/controllers_emitter"
require "cybertrain/generator/manifest"
require "cybertrain/schema"
require "cybertrain/generator/model_scan"
require "cybertrain/generator/models_emitter"

module Cybertrain
  module Gen
    # `spin run gen`: regenerates gen/ from the drawn routes and app/.
    # A file whose content would not change is left alone (its mtime too).
    # With --check nothing is written; each out-of-date file is reported as
    # "stale: <path>" and the exit code is 1.
    module Runner
      def self.run(root, argv)
        check = argv.include?("--check")
        outputs = [
          ["gen/routes.rb", RoutesEmitter.emit(Cybertrain::Routes.specs)],
          ["gen/controllers.rb", ControllersEmitter.emit(ControllerScan.scan_dir("#{root}/app/controllers"))]
        ]
        # gen/models/<model>.rb per table once db/schema.rb has been loaded.
        schema = Cybertrain::Schema.current
        stale = 0
        if schema.nil?
          outputs.each { |pair| stale += sync_file(root, pair[0], pair[1], check) }
          stale += sync_file(root, "gen/app.rb", Manifest.emit(root), check)
        else
          infos = ModelScan.scan_dir("#{root}/app/models")
          models = Array.new(0) { "" }
          ModelsEmitter.outputs(schema, infos).each do |rel, source|
            outputs << [rel, source]
            models << rel.delete_suffix(".rb")
          end
          models = models.sort
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
          Dir.mkdir("#{root}/gen") unless File.directory?("#{root}/gen")
          dir = File.dirname(path)
          Dir.mkdir(dir) unless File.directory?(dir)
          File.write(path, source)
          puts "wrote #{rel}"
          0
        end
      end
    end
  end
end
