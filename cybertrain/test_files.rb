# Which files of an application are its tests (spec 5.2, 8): shared by gen
# (Gen::TestScan) and `cybertrain test`, so the two never disagree. No
# requires: the CLI loads it without the generator.
module Cybertrain
  module TestFiles
    HELPER = "test/test_helper.rb".freeze

    # "test/models/article_test.rb", ... under root: every
    # test/**/*_test.rb and every test/*.rb except test/test_helper.rb,
    # never a file under test/support/ or test/fixtures/; sorted.
    def self.list(root)
      out = Array.new(0) { "" }
      walk(root, "test", out)
      picked = Array.new(0) { "" }
      out.each do |rel|
        next if rel == HELPER
        next if rel.start_with?("test/support/") || rel.start_with?("test/fixtures/")

        top = rel.index("/", 5).nil?
        picked << rel if top || rel.end_with?("_test.rb")
      end
      picked.sort
    end

    # test/support/**/*.rb under root, sorted.
    def self.support_files(root)
      out = Array.new(0) { "" }
      walk(root, "test/support", out)
      out.sort
    end

    # Appends every .rb file under root/rel (as "rel/..."), depth first.
    def self.walk(root, rel, out)
      dir = "#{root}/#{rel}"
      return nil unless File.directory?(dir)

      Dir.children(dir).sort.each do |entry|
        child = "#{rel}/#{entry}"
        if File.directory?("#{root}/#{child}")
          walk(root, child, out)
        elsif entry.end_with?(".rb")
          out << child
        end
      end
      nil
    end
  end
end
