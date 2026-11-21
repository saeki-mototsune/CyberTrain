# Shared by the framework tests that build a scratch tree on disk (each one
# `require_relative "support/file_tree"`). Not a test program itself:
# script/gate and script/test-shard read test/*.rb only.
#
# Paths are Strings throughout. A test that calls only one of the three
# still compiles the other two.
module FileTree
  # Removes a file, a symlink (itself, never followed) or a directory with
  # what it holds; a path that is not there is left alone.
  def self.remove(path)
    if File.symlink?(path)
      File.delete(path)
    elsif File.directory?(path)
      Dir.children(path).each { |child| FileTree.remove("#{path}/#{child}") }
      Dir.rmdir(path)
    elsif File.exist?(path)
      File.delete(path)
    end
    nil
  end

  # Copies the directory +from+ and what it holds to +to+, made when missing.
  def self.copy(from, to)
    Dir.mkdir(to) unless File.directory?(to)
    Dir.children(from).sort.each do |entry|
      if File.directory?("#{from}/#{entry}")
        FileTree.copy("#{from}/#{entry}", "#{to}/#{entry}")
      else
        File.write("#{to}/#{entry}", File.read("#{from}/#{entry}"))
      end
    end
    nil
  end

  # Makes +dir+ and the directories above it that are missing.
  def self.make_dirs(dir)
    return nil if File.directory?(dir)

    FileTree.make_dirs(File.dirname(dir))
    Dir.mkdir(dir)
    nil
  end
end
