# The directory of spinel-http, cybertrain's HTTP layer (docs/design.md
# D91), for the scripts that read or load its source under CRuby: the root
# of the checkout spin.lock pins, the directory that holds spinel-http.rb
# and spinel-http/*.rb, so it goes on $LOAD_PATH (`-I`) as it does for
# `spin build`.
#
# With spin on PATH it is the `-I` directory of `spin flags` that holds
# spinel-http.rb: spin fetches the locked commit into its cache first when
# it is missing. Without spin (the Gate workflow runs CRuby alone), the
# commit spin.lock pins is fetched with git into tmp/spinel-http-<sha>/
# (ignored by git), once.
#
# usage: require_relative "spinel_http_path"; SpinelHttpPath.root
#        ruby script/spinel_http_path.rb      prints the directory
require "open3"
require "fileutils"

module SpinelHttpPath
  ROOT = File.expand_path("..", __dir__)

  # The directory, fetched when needed; aborts with the reason when it
  # cannot be had.
  # @return [String]
  def self.root
    @root ||= from_spin || from_lock
  end

  # The `-I` directory of `spin flags` holding spinel-http.rb, nil without
  # spin.
  def self.from_spin
    out, status = Open3.capture2e("spin", "flags", chdir: ROOT)
    abort "spinel_http_path: `spin flags` failed:\n#{out}" unless status.success?

    dirs = out.split.each_cons(2).select { |flag, _| flag == "-I" }.map(&:last)
    found = dirs.find { |d| File.file?(File.join(d, "spinel-http.rb")) }
    abort "spinel_http_path: no -I directory of `spin flags` holds spinel-http.rb: #{out.strip}" if found.nil?

    found
  rescue Errno::ENOENT
    nil
  end

  # The commit spin.lock pins, fetched with git into tmp/.
  def self.from_lock
    lock = File.read(File.join(ROOT, "spin.lock"))
    entry = lock[/^\[lock\.spinel-http\]\n((?:[^\[\n].*\n?)*)/, 1].to_s
    url = entry[/^git = "([^"]+)"/, 1]
    sha = entry[/^ref = "([0-9a-f]{40})"/, 1]
    abort "spinel_http_path: spin.lock pins no git commit of spinel-http" if url.nil? || sha.nil?

    dir = File.join(ROOT, "tmp", "spinel-http-#{sha}")
    return dir if File.file?(File.join(dir, "spinel-http.rb"))

    work = "#{dir}.fetch-#{Process.pid}"
    FileUtils.rm_rf(work)
    FileUtils.mkdir_p(work)
    [%w[init -q], ["fetch", "-q", "--depth", "1", url, sha], %w[checkout -q FETCH_HEAD]].each do |args|
      out, status = Open3.capture2e("git", *args, chdir: work)
      abort "spinel_http_path: git #{args.join(" ")} failed:\n#{out}" unless status.success?
    end
    FileUtils.rm_rf(dir)
    File.rename(work, dir)
    dir
  end
end

puts SpinelHttpPath.root if $PROGRAM_NAME == __FILE__
