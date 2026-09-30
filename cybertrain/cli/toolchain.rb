# The Spinel toolchain the CLI runs `spin` with. `cybertrain new`, `db`,
# `server`, `build` and `spin` call Toolchain.ensure! before their first
# spin command: it uses a `spinel`/`spin` of the pinned release already on
# PATH, or the copy it keeps under ~/.cybertrain, or builds that copy from
# the release tag (git clone, make deps, make, make install), the same steps
# CI runs. `cybertrain setup` does it explicitly; `cybertrain doctor`
# reports.
#
# Plain Ruby: runs under CRuby (the gem) and compiles under Spinel
# (bin/cybertrain.rb), so it shells out with `system` and backticks and
# reads files instead of using Open3, RbConfig or Etc.
require "cybertrain/version"

module Cybertrain
  module CLI
    module Toolchain
      SPINEL_GIT = "https://github.com/matz/spinel.git"
      STALE_LOCK_SECONDS = 7200
      LOCK_WAIT_SECONDS = 3600

      # ---- locations -----------------------------------------------------

      # CYBERTRAIN_HOME, or ~/.cybertrain, as an absolute path (a leading
      # `~` and relative paths are expanded). "" when neither CYBERTRAIN_HOME
      # nor HOME is set.
      def self.home
        dir = ENV["CYBERTRAIN_HOME"].to_s
        base = ENV["HOME"].to_s
        dir = File.join(base, ".cybertrain") if dir == "" && base != ""
        return "" if dir == ""
        return "" if dir.start_with?("~") && base == ""

        File.expand_path(dir)
      end

      def self.tag
        Cybertrain::SPINEL_TAG
      end

      # `make install PREFIX=` target of the managed copy.
      def self.prefix
        File.join(home, "spinel", tag)
      end

      def self.bin_dir
        File.join(prefix, "bin")
      end

      # ~/.cybertrain/bin: `spinel` and `spin` symlinks to the managed release
      # in use, so one PATH entry keeps working across a SPINEL_TAG bump.
      def self.stable_bin_dir
        File.join(home, "bin")
      end

      # Written when an install finished and checked out; a half-updated
      # prefix (an interrupted `setup --force`) has none and is rebuilt.
      def self.stamp
        File.join(prefix, ".cybertrain-complete")
      end

      def self.src_dir
        File.join(home, "src", "spinel-#{tag}")
      end

      def self.log_path
        File.join(home, "log", "spinel-#{tag}-build.log")
      end

      def self.lock_dir
        File.join(home, "spinel", "#{tag}.lock")
      end

      # ---- discovery -----------------------------------------------------

      # The release inside the parentheses of `spinel --version`, which come
      # before the compiler field: "spinel 112bae85c1a2 (2026.09.12) [cc
      # (Ubuntu 13.3.0) 13.3.0]" -> "2026.09.12". "" when there is none.
      def self.release_of(version_line)
        head = version_line.split(" [")[0].to_s
        open = head.index("(")
        close = head.index(")")
        return "" if open.nil? || close.nil? || close <= open

        head[open + 1, close - open - 1].to_s
      end

      # The release the spinel binary at `path` reports; "" when it cannot run.
      def self.release_at(path)
        release_of(sh_read("#{shell_quote(path)} --version"))
      end

      # dir holds an executable spinel and spin, and that spinel is the pinned
      # release.
      def self.usable?(dir)
        spinel = File.join(dir, "spinel")
        spin = File.join(dir, "spin")
        return false unless File.file?(spinel) && File.executable?(spinel)
        return false unless File.file?(spin) && File.executable?(spin)

        release_at(spinel) == tag
      end

      # The managed copy is complete and of the pinned release.
      def self.managed_ok?
        usable?(bin_dir) && File.exist?(stamp)
      end

      # The spinel PATH resolves to, as an absolute path; "" when none.
      def self.spinel_on_path
        found = sh_read("command -v spinel")
        found == "" ? "" : File.expand_path(found)
      end

      # A spinel of the pinned release, with the spin from the same
      # directory, is already on PATH.
      def self.on_path?
        spinel = spinel_on_path
        return false if spinel == ""

        spin = sh_read("command -v spin")
        return false if spin == ""
        return false unless File.dirname(File.expand_path(spin)) == File.dirname(spinel)

        release_at(spinel) == tag
      end

      # The bin directory CYBERTRAIN_SPINEL_HOME names, absolute: the
      # prefix's bin/, or the directory itself when it holds spinel directly.
      # "" when the variable is unset.
      def self.explicit_bin_dir
        given = ENV["CYBERTRAIN_SPINEL_HOME"].to_s
        return "" if given == ""

        given = File.expand_path(given)
        return given if File.file?(File.join(given, "spinel"))

        File.join(given, "bin")
      end

      def self.explicit_error(explicit)
        "error: CYBERTRAIN_SPINEL_HOME=#{ENV["CYBERTRAIN_SPINEL_HOME"]} has no spinel #{tag} and spin in #{explicit}"
      end

      # ---- ensuring ------------------------------------------------------

      # Puts a toolchain of the pinned release on this process's PATH (so
      # `spin` in a `system` call is that one), installing the managed copy
      # first when nothing else qualifies. Returns false, after explaining,
      # when it could not.
      def self.ensure!
        explicit = explicit_bin_dir
        unless explicit == ""
          return use(explicit) if usable?(explicit)

          puts explicit_error(explicit)
          return false
        end
        return true if on_path?
        return use(bin_dir) if managed_ok?
        return false unless install(false)

        use(bin_dir)
      end

      # `cybertrain setup [--force]`, given the words after `setup`: the
      # exit code.
      def self.setup(args)
        force = false
        args.each do |arg|
          if arg == "--force"
            force = true
          else
            puts "usage: cybertrain setup [--force]"
            return 1
          end
        end
        explicit = explicit_bin_dir
        unless explicit == ""
          puts "note: --force is ignored while CYBERTRAIN_SPINEL_HOME is set" if force
          if usable?(explicit)
            puts "spinel #{tag} is in #{explicit} (CYBERTRAIN_SPINEL_HOME); nothing to install"
            return 0
          end
          puts explicit_error(explicit)
          puts "  unset it to let cybertrain install its own copy under #{prefix}"
          return 1
        end
        if !force && on_path?
          puts "spinel #{tag} is on PATH: #{spinel_on_path}"
          puts "nothing to install"
          return 0
        end
        if !force && managed_ok?
          link_stable_bin
          puts "spinel #{tag} is installed in #{bin_dir}; nothing to install (--force rebuilds it)"
          print_path_hint
          return 0
        end
        install(force) ? 0 : 1
      end

      def self.use(dir)
        ENV["PATH"] = "#{dir}:#{ENV["PATH"]}"
        true
      end

      # Points ~/.cybertrain/bin/{spinel,spin} at the managed release.
      def self.link_stable_bin
        return unless system("mkdir -p #{shell_quote(stable_bin_dir)} 2>/dev/null")

        ["spinel", "spin"].each do |name|
          system("ln -sfn #{shell_quote(File.join(bin_dir, name))} #{shell_quote(File.join(stable_bin_dir, name))} 2>/dev/null")
        end
      end

      def self.print_path_hint
        puts "cybertrain uses it by itself; `cybertrain spin ...` runs spin with it, or put it on PATH:"
        puts "  export PATH=\"#{stable_bin_dir}:$PATH\""
      end

      # The note for a spinel of another release on PATH, which is left
      # alone (the framework is tested against one release); "" when PATH
      # has none or has the pinned one.
      def self.other_release_note
        spinel = spinel_on_path
        return "" if spinel == ""

        release = release_at(spinel)
        return "" if release == tag

        shown = release == "" ? "an unknown release" : "release #{release}"
        "note: #{spinel} is #{shown}; cybertrain #{Cybertrain::VERSION} is pinned to Spinel #{tag} and keeps its own copy in #{prefix}"
      end

      def self.note_other_release
        note = other_release_note
        puts note unless note == ""
      end

      # ---- installing ----------------------------------------------------

      # Builds and installs the pinned release into prefix. Returns false
      # after printing why when a prerequisite is missing or a step fails.
      def self.install(force)
        if home == ""
          puts "error: neither CYBERTRAIN_HOME nor HOME is set; cybertrain needs one of them to keep Spinel in"
          return false
        end
        unless prefix.match(/[\s'"`$\\;&|<>()*?]/).nil?
          puts "error: Spinel's Makefile cannot install into #{prefix}; set CYBERTRAIN_HOME to a path without spaces, quotes or $"
          return false
        end
        problems = missing_requirements
        unless problems.empty?
          puts "error: cannot build Spinel #{tag}: missing #{problems.join(", ")}"
          install_hints.each { |line| puts "  #{line}" }
          return false
        end
        note_other_release
        return false unless take_lock

        begin
          return true if !force && managed_ok? # another process finished it while we waited

          puts "Installing Spinel #{tag} into #{prefix} (one-time; a few minutes)"
          puts "  log: #{log_path}"
          File.delete(stamp) if File.exist?(stamp)
          system("mkdir -p #{shell_quote(File.dirname(log_path))} #{shell_quote(File.dirname(src_dir))} 2>/dev/null")
          unless File.directory?(File.dirname(log_path)) && File.directory?(File.dirname(src_dir))
            puts "error: cannot write under #{home}; set CYBERTRAIN_HOME to a writable directory"
            return false
          end
          system("rm -rf #{shell_quote(src_dir)}")
          File.write(log_path, "")
          steps = [
            ["clone", "git clone -q --depth 1 --branch #{tag} #{SPINEL_GIT} #{shell_quote(src_dir)}"],
            ["deps", "cd #{shell_quote(src_dir)} && make deps"],
            ["build", "cd #{shell_quote(src_dir)} && make -j#{jobs}"],
            ["install", "cd #{shell_quote(src_dir)} && make install PREFIX=#{shell_quote(prefix)}"]
          ]
          steps.each do |step|
            puts "  #{step[0]}: #{step[1]}"
            next if system("(#{step[1]}) >> #{shell_quote(log_path)} 2>&1")

            puts "error: Spinel #{step[0]} failed; the last lines of #{log_path}:"
            tail(log_path, 25).each { |line| puts "  | #{line}" }
            return false
          end
          unless ENV["CYBERTRAIN_KEEP_SRC"].to_s == "1"
            system("rm -rf #{shell_quote(src_dir)}")
            system("rmdir #{shell_quote(File.dirname(src_dir))} 2>/dev/null")
          end
          unless usable?(bin_dir)
            puts "error: the install finished but #{bin_dir} does not hold spinel #{tag} and spin (see #{log_path})"
            return false
          end
          File.write(stamp, "#{tag}\n")
          link_stable_bin
          puts ""
          puts "installed spinel #{tag} in #{bin_dir}"
          print_path_hint
          true
        ensure
          release_lock
        end
      end

      # One build at a time per home. The lock is a directory holding the
      # builder's pid, taken by renaming a staging directory (already
      # holding the pid) onto the lock path: rename is atomic and refuses to
      # replace a non-empty directory, so a lock is never seen half-made. A
      # lock whose pid is gone or invalid, or older than STALE_LOCK_SECONDS,
      # is moved aside and taken over.
      def self.take_lock
        parent = File.dirname(lock_dir)
        unless system("mkdir -p #{shell_quote(parent)} 2>/dev/null") && File.directory?(parent)
          puts "error: cannot create #{parent}; set CYBERTRAIN_HOME to a writable directory"
          return false
        end
        staging = "#{lock_dir}.#{Process.pid}"
        system("rm -rf #{shell_quote(staging)}")
        begin
          Dir.mkdir(staging)
          File.write(File.join(staging, "pid"), Process.pid.to_s)
        rescue StandardError
          puts "error: cannot write in #{parent}; set CYBERTRAIN_HOME to a writable directory"
          return false
        end
        waited = 0
        while true
          taken = false
          begin
            File.rename(staging, lock_dir)
            taken = true
          rescue StandardError
            taken = false # held by someone: rename cannot replace a non-empty directory
          end
          return true if taken

          if lock_stale?
            aside = "#{lock_dir}.stale.#{Process.pid}"
            begin
              File.rename(lock_dir, aside)
              system("rm -rf #{shell_quote(aside)}")
            rescue StandardError
              nil # another waiter moved it first
            end
            next
          end
          puts "another cybertrain (pid #{lock_pid}) is installing Spinel #{tag}; waiting (remove #{lock_dir} if no build is running)" if waited == 0
          if waited >= LOCK_WAIT_SECONDS
            puts "error: gave up waiting for pid #{lock_pid}; remove #{lock_dir} if it is stale"
            system("rm -rf #{shell_quote(staging)}")
            return false
          end
          sleep 5
          waited += 5
        end
      end

      # The lock exists but its holder is gone, unrecorded, or has held it
      # for longer than a build can take.
      def self.lock_stale?
        return false unless File.directory?(lock_dir)

        pid = lock_pid
        return true if pid.match(/\A[1-9][0-9]*\z/).nil?
        return true unless system("kill -0 #{pid} 2>/dev/null")

        Time.now.to_i - File.mtime(lock_dir).to_i > STALE_LOCK_SECONDS
      end

      def self.release_lock
        system("rm -rf #{shell_quote(lock_dir)}") if lock_pid == Process.pid.to_s
      end

      def self.lock_pid
        path = File.join(lock_dir, "pid")
        return "" unless File.exist?(path)

        File.read(path).strip
      end

      # `make -j` width: the CPU count, at least 1.
      def self.jobs
        n = sh_read("nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null").to_i
        n < 1 ? 1 : n
      end

      # ---- requirements --------------------------------------------------

      # The C compiler command, possibly with arguments ("ccache gcc").
      def self.cc
        given = ENV["CC"].to_s
        given == "" ? "cc" : given
      end

      def self.cc_program
        cc.split(" ")[0].to_s
      end

      def self.have_command?(name)
        sh_read("command -v #{shell_quote(name)}") != ""
      end

      # A C program using `include` and `link` compiles and links: the
      # header and the library are both installed.
      def self.compiles?(include, body, link)
        dir = sh_read("mktemp -d 2>/dev/null")
        return false if dir == ""

        source = File.join(dir, "probe.c")
        File.write(source, "#include <#{include}>\nint main(void) { return #{body}; }\n")
        ok = system("#{cc} #{shell_quote(source)} -o #{shell_quote(File.join(dir, "probe"))} #{link} > /dev/null 2>&1")
        system("rm -rf #{shell_quote(dir)}")
        ok
      end

      def self.sqlite_ok?
        compiles?("sqlite3.h", "sqlite3_libversion_number() > 0 ? 0 : 1", "-lsqlite3")
      end

      # Spinel's own Makefile finds a Homebrew OpenSSL by itself; this probe
      # only decides whether to warn.
      def self.openssl_ok?
        return true if compiles?("openssl/ssl.h", "TLS_client_method() != 0 ? 0 : 1", "-lssl -lcrypto")

        brew = sh_read("brew --prefix openssl@3 2>/dev/null")
        return false if brew == ""

        compiles?("openssl/ssl.h", "TLS_client_method() != 0 ? 0 : 1",
                  "-I#{shell_quote(File.join(brew, "include"))} -L#{shell_quote(File.join(brew, "lib"))} -lssl -lcrypto")
      end

      # What a Spinel build cannot do without, by name. OpenSSL is not in
      # this list: without its headers Spinel builds without its openssl
      # package, which cybertrain does not use.
      def self.missing_requirements
        missing = Array.new(0) { "" }
        if platform == "darwin" && !system("xcode-select -p > /dev/null 2>&1")
          missing << "the Xcode Command Line Tools (xcode-select --install)"
          return missing
        end
        missing << "git" unless have_command?("git")
        missing << "make" unless have_command?("make")
        missing << "curl" unless have_command?("curl")
        missing_app_requirements.each { |name| missing << name }
        missing
      end

      # What building an application needs even once Spinel is installed.
      def self.missing_app_requirements
        missing = Array.new(0) { "" }
        unless have_command?(cc_program)
          missing << "a C compiler (#{cc})"
          return missing
        end
        missing << "the SQLite 3 headers and library" unless sqlite_ok?
        missing
      end

      # "linux", "darwin" or "" from uname, plus the distribution family from
      # /etc/os-release (debian, rhel, arch, alpine, suse) for the hint.
      def self.platform
        os = sh_read("uname -s").downcase
        return "darwin" if os.start_with?("darwin")
        return "" unless os.start_with?("linux")

        os_release = File.exist?("/etc/os-release") ? File.read("/etc/os-release").downcase : ""
        return "debian" if os_release.include?("debian") || os_release.include?("ubuntu")
        return "rhel" if os_release.include?("rhel") || os_release.include?("fedora") || os_release.include?("centos")
        return "arch" if os_release.include?("arch")
        return "alpine" if os_release.include?("alpine")
        return "suse" if os_release.include?("suse")

        "linux"
      end

      # The command that installs every requirement on this platform.
      def self.install_hints
        case platform
        when "debian"
          ["sudo apt-get update && sudo apt-get install -y build-essential git curl libsqlite3-dev libssl-dev"]
        when "rhel"
          ["sudo dnf install -y gcc make git curl sqlite-devel openssl-devel"]
        when "arch"
          ["sudo pacman -S --needed base-devel git curl sqlite openssl"]
        when "alpine"
          ["sudo apk add build-base git curl sqlite-dev openssl-dev"]
        when "suse"
          ["sudo zypper install -y gcc make git curl sqlite3-devel libopenssl-devel"]
        when "darwin"
          ["xcode-select --install     # cc, make, git, curl and the SQLite headers",
           "brew install openssl@3     # optional: Spinel's openssl package"]
        else
          ["install git, make, curl, a C compiler and the SQLite 3 development headers with your package manager"]
        end
      end

      # ---- doctor --------------------------------------------------------

      # `cybertrain doctor`: prints one line per check. The exit code is 0
      # when a Spinel of the pinned release is usable and applications can
      # be built, or when nothing stops `cybertrain setup` from building
      # one; 1 otherwise.
      def self.doctor
        puts "cybertrain #{Cybertrain::VERSION}, pinned to Spinel #{tag}"
        puts "home      #{home == "" ? "(unset: set CYBERTRAIN_HOME or HOME)" : home}"
        report("git", have_command?("git"), sh_read("command -v git"))
        report("make", have_command?("make"), sh_read("command -v make"))
        report("curl", have_command?("curl"), sh_read("command -v curl"))
        report("cc", have_command?(cc_program), sh_read("#{cc} --version 2>/dev/null | head -n 1"))
        if have_command?(cc_program)
          report("sqlite3", sqlite_ok?, sqlite_ok? ? "headers and library found" : "sqlite3.h or -lsqlite3 missing")
          if openssl_ok?
            report("openssl", true, "headers and library found")
          else
            info("openssl", "not found: Spinel builds without its openssl package, which cybertrain does not use")
          end
        end
        ready = doctor_spinel
        problems = ready ? missing_app_requirements : missing_requirements
        problems << "a usable CYBERTRAIN_SPINEL_HOME" if !ready && explicit_bin_dir != ""
        return 0 if problems.empty?

        puts ""
        puts "missing: #{problems.join(", ")}"
        install_hints.each { |line| puts "  #{line}" } unless ready
        1
      end

      # The spinel lines; true when one of the pinned release is usable.
      def self.doctor_spinel
        explicit = explicit_bin_dir
        unless explicit == ""
          ok = usable?(explicit)
          report("spinel", ok, "#{explicit} (CYBERTRAIN_SPINEL_HOME, #{release_label(File.join(explicit, "spinel"))})")
          return ok
        end
        found = false
        on_path = spinel_on_path
        if on_path != ""
          if on_path?
            report("spinel", true, "#{on_path} on PATH (#{release_label(on_path)})")
            found = true
          else
            info("spinel", "#{on_path} on PATH is #{release_label(on_path)}; not used (pinned to #{tag})")
          end
        end
        if managed_ok?
          report("spinel", true, "#{bin_dir} (managed, #{tag})")
          found = true
        elsif !found
          info("spinel", "not installed; `cybertrain setup` builds #{tag} into #{prefix}")
        end
        found
      end

      def self.release_label(spinel)
        release = release_at(spinel)
        release == "" ? "release unknown" : "release #{release}"
      end

      def self.report(name, ok, detail)
        puts "#{name.ljust(9)} #{(ok ? "ok" : "MISSING").ljust(7)}   #{detail}"
      end

      def self.info(name, detail)
        puts "#{name.ljust(9)} #{"--".ljust(7)}   #{detail}"
      end

      # ---- shell helpers -------------------------------------------------

      # stdout of a shell command (a pipeline or an `a || b` list too),
      # stripped; "" on failure.
      def self.sh_read(command)
        `(#{command}) 2>/dev/null`.strip
      end

      def self.tail(path, count)
        return Array.new(0) { "" } unless File.exist?(path)

        lines = File.read(path).split("\n")
        from = lines.size > count ? lines.size - count : 0
        lines[from, lines.size - from]
      end

      def self.shell_quote(text)
        "'#{text.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
