# The directory of spinel-http, cybertrain's HTTP layer (docs/design.md
# D91), for the scripts that read or load its source under CRuby: the root
# of the checkout spin.lock pins, the directory that holds spinel-http.rb
# and spinel-http/*.rb, so it goes on $LOAD_PATH (`-I`) as it does for
# `spin build`.
#
# With spin on PATH it is the `-I` directory of `spin flags` that holds
# spinel-http.rb: spin fetches the locked commit into its cache first when
# it is missing. Without spin (the Gate workflow runs CRuby alone), or when
# `spin flags` fails (offline with a cold cache, say), the commit spin.lock
# pins is fetched with git into tmp/spinel-http-<sha>/ (ignored by git),
# once. Two processes may do that at once: each fetches into a directory of
# its own and renames it into place, and the one whose rename finds the
# directory already there uses it.
#
# usage: require_relative "spinel_http_path"; SpinelHttpPath.root
#        ruby script/spinel_http_path.rb      prints the directory
require "open3"
require "fileutils"
require "tmpdir"

module SpinelHttpPath
  ROOT = File.expand_path("..", __dir__)

  # The directory, fetched when needed; aborts with the reason when it
  # cannot be had.
  # @return [String]
  def self.root
    @root ||= from_spin || from_lock
  end

  # The `-I` directory of `spin flags` holding spinel-http.rb; nil without
  # spin, or when `spin flags` fails (then the lock decides).
  def self.from_spin
    out, status = Open3.capture2e("spin", "flags", chdir: ROOT)
    unless status.success?
      warn "spinel_http_path: `spin flags` failed, fetching the commit spin.lock pins instead:\n#{out}"
      return nil
    end

    found = include_dirs(out).find { |d| File.file?(File.join(d, "spinel-http.rb")) }
    abort "spinel_http_path: no -I directory of `spin flags` holds spinel-http.rb: #{out.strip}" if found.nil?

    found
  rescue Errno::ENOENT
    nil
  end

  # The `-I` directories in `spin flags` output. spin prints the flags on
  # one line, space-separated and unquoted, so the line is cut only at a
  # space that starts another flag (` -`): a directory whose name holds a
  # space survives, one that holds " -" does not.
  # @param out [String]
  # @return [Array<String>]
  def self.include_dirs(out)
    out.strip.split(/ (?=-)/).filter_map { |flag| flag.delete_prefix("-I ") if flag.start_with?("-I ") }
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

    FileUtils.mkdir_p(File.dirname(dir))
    work = Dir.mktmpdir("spinel-http-#{sha}.fetch-", File.dirname(dir))
    [%w[init -q], ["fetch", "-q", "--depth", "1", url, sha], %w[checkout -q FETCH_HEAD]].each do |args|
      out, status = Open3.capture2e("git", *args, chdir: work)
      next if status.success?

      FileUtils.rm_rf(work)
      abort "spinel_http_path: git #{args.join(" ")} failed:\n#{out}"
    end
    place(work, dir)
  end

  # Renames the finished fetch into place. Another process may have put
  # its own there first: then that one is used and this one dropped.
  def self.place(work, dir)
    File.rename(work, dir)
    dir
  rescue Errno::EEXIST, Errno::ENOTEMPTY
    FileUtils.rm_rf(work)
    return dir if File.file?(File.join(dir, "spinel-http.rb"))

    abort "spinel_http_path: #{dir} exists but holds no spinel-http.rb; remove it and run again"
  end
end

puts SpinelHttpPath.root if $PROGRAM_NAME == __FILE__
