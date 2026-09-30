# The Spinel toolchain the CLI runs `spin` with. `cybertrain new`, `db`,
# `server` and `build` call Toolchain.ensure! before their first spin
# command: it uses a `spinel`/`spin` of the pinned release already on PATH,
# or the copy it keeps under ~/.cybertrain, or builds that copy from the
# release tag (git clone, make deps, make, make install), the same steps CI
# runs. `cybertrain setup` does it explicitly; `cybertrain doctor` reports.
#
# Plain Ruby: runs under CRuby (the gem) and compiles under Spinel
# (bin/cybertrain.rb), so it shells out with `system` and reads files
# instead of using Open3, RbConfig or Etc.
require "cybertrain/version"

module Cybertrain
  module CLI
    module Toolchain
      SPINEL_GIT = "https://github.com/matz/spinel.git"

      # ---- locations -----------------------------------------------------

      # CYBERTRAIN_HOME, or ~/.cybertrain.
      def self.home
        dir = ENV["CYBERTRAIN_HOME"].to_s
        return dir unless dir == ""

        File.join(ENV["HOME"].to_s, ".cybertrain")
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

      # The release inside the parentheses of `spinel --version`:
      # "spinel 112bae85c1a2 (2026.09.12) [cc ...]" -> "2026.09.12". "" when
      # the line has no such field.
      def self.release_of(version_line)
        open = version_line.index("(")
        close = version_line.index(")")
        return "" if open.nil? || close.nil? || close <= open

        version_line[open + 1, close - open - 1].to_s
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

      # The spinel found on PATH ("" when none) and its release.
      def self.spinel_on_path
        sh_read("command -v spinel")
      end

      # A spinel of the pinned release, with spin, is already on PATH.
      def self.on_path?
        spinel = spinel_on_path
        return false if spinel == ""
        return false if sh_read("command -v spin") == ""

        release_at(spinel) == tag
      end

      # The bin directory named by CYBERTRAIN_SPINEL_HOME: the prefix's bin/,
      # or the directory itself when it holds spinel directly. "" when unset.
      def self.explicit_bin_dir
        given = ENV["CYBERTRAIN_SPINEL_HOME"].to_s
        return "" if given == ""
        return given if File.file?(File.join(given, "spinel"))

        File.join(given, "bin")
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

          puts "error: CYBERTRAIN_SPINEL_HOME=#{ENV["CYBERTRAIN_SPINEL_HOME"]} has no spinel #{tag} and spin in #{explicit}"
          return false
        end
        return true if on_path?
        return use(bin_dir) if usable?(bin_dir)

        note_other_release
        return false unless install(false)

        use(bin_dir)
      end

      # `cybertrain setup [--force]`: the exit code.
      def self.setup(force)
        explicit = explicit_bin_dir
        unless explicit == ""
          if usable?(explicit)
            puts "spinel #{tag} is in #{explicit} (CYBERTRAIN_SPINEL_HOME); nothing to install"
            return 0
          end
          puts "error: CYBERTRAIN_SPINEL_HOME=#{ENV["CYBERTRAIN_SPINEL_HOME"]} has no spinel #{tag} and spin in #{explicit}"
          puts "  unset it to let cybertrain install its own copy under #{prefix}"
          return 1
        end
        if !force && on_path?
          puts "spinel #{tag} is on PATH: #{spinel_on_path}"
          puts "nothing to install"
          return 0
        end
        if !force && usable?(bin_dir)
          puts "spinel #{tag} is installed in #{bin_dir}; nothing to install (--force rebuilds it)"
          print_path_hint
          return 0
        end

        note_other_release
        return 1 unless install(force)

        puts ""
        puts "installed spinel #{tag} in #{bin_dir}"
        print_path_hint
        0
      end

      def self.print_path_hint
        puts "cybertrain uses it by itself; to run spin directly:"
        puts "  export PATH=\"#{bin_dir}:$PATH\""
      end

      def self.use(dir)
        ENV["PATH"] = "#{dir}:#{ENV["PATH"]}"
        true
      end

      # A spinel of another release on PATH is left alone, and said so once
      # (the framework is tested against one release).
      def self.note_other_release
        spinel = spinel_on_path
        return if spinel == ""

        release = release_at(spinel)
        return if release == tag

        shown = release == "" ? "an unknown release" : "release #{release}"
        puts "note: #{spinel} is #{shown}; cybertrain #{Cybertrain::VERSION} is pinned to Spinel #{tag} and keeps its own copy in #{prefix}"
      end

      # ---- installing ----------------------------------------------------

      # Builds and installs the pinned release into prefix. Returns false
      # after printing why when a prerequisite is missing or a step fails.
      def self.install(force)
        problems = missing_requirements
        unless problems.empty?
          puts "error: cannot build Spinel #{tag}: missing #{problems.join(", ")}"
          install_hints.each { |line| puts "  #{line}" }
          return false
        end
        return false unless take_lock

        begin
          return true if !force && usable?(bin_dir) # another process finished it while we waited

          puts "Installing Spinel #{tag} into #{prefix} (one-time; a few minutes)"
          puts "  log: #{log_path}"
          system("mkdir -p #{shell_quote(File.dirname(log_path))} #{shell_quote(File.dirname(src_dir))}")
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
          true
        ensure
          release_lock
        end
      end

      # One build at a time per home: a directory as the lock (mkdir is
      # atomic), holding the builder's PID so a lock left by a killed build
      # is recognised and taken over.
      def self.take_lock
        system("mkdir -p #{shell_quote(File.dirname(lock_dir))}")
        waited = 0
        until system("mkdir #{shell_quote(lock_dir)} 2>/dev/null")
          pid = lock_pid
          if pid == "" || !system("kill -0 #{pid} 2>/dev/null")
            system("rm -rf #{shell_quote(lock_dir)}")
            next
          end
          puts "another cybertrain (pid #{pid}) is installing Spinel #{tag}; waiting" if waited == 0
          if waited >= 3600
            puts "error: gave up waiting for pid #{pid}; remove #{lock_dir} if it is stale"
            return false
          end
          sleep 5
          waited += 5
        end
        File.write(File.join(lock_dir, "pid"), Process.pid.to_s)
        true
      end

      def self.release_lock
        system("rm -rf #{shell_quote(lock_dir)}")
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

      def self.cc
        given = ENV["CC"].to_s
        given == "" ? "cc" : given
      end

      def self.have_command?(name)
        sh_read("command -v #{shell_quote(name)}") != ""
      end

      # A C program using `include` and `link` compiles and links: the
      # header and the library are both installed.
      def self.compiles?(include, body, link)
        base = File.join(tmpdir, "cybertrain-probe-#{Process.pid}")
        File.write("#{base}.c", "#include <#{include}>\nint main(void) { return #{body}; }\n")
        ok = system("#{cc} #{shell_quote("#{base}.c")} -o #{shell_quote(base)} #{link} > /dev/null 2>&1")
        system("rm -f #{shell_quote("#{base}.c")} #{shell_quote(base)}")
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
        missing << "git" unless have_command?("git")
        missing << "make" unless have_command?("make")
        missing << "curl" unless have_command?("curl")
        missing << "a C compiler (#{cc})" unless have_command?(cc)
        missing << "the SQLite 3 headers and library" if have_command?(cc) && !sqlite_ok?
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

      # `cybertrain doctor`: prints one line per check; the exit code is 1
      # when a Spinel build could not start here.
      def self.doctor
        puts "cybertrain #{Cybertrain::VERSION}, pinned to Spinel #{tag}"
        puts "home      #{home}"
        report("git", have_command?("git"), sh_read("command -v git"))
        report("make", have_command?("make"), sh_read("command -v make"))
        report("curl", have_command?("curl"), sh_read("command -v curl"))
        report("cc", have_command?(cc), sh_read("#{shell_quote(cc)} --version 2>/dev/null | head -n 1"))
        if have_command?(cc)
          report("sqlite3", sqlite_ok?, sqlite_ok? ? "headers and library found" : "sqlite3.h or -lsqlite3 missing")
          if openssl_ok?
            report("openssl", true, "headers and library found")
          else
            puts "openssl   --   not found: Spinel builds without its openssl package, which cybertrain does not use"
          end
        end
        doctor_spinel
        problems = missing_requirements
        return 0 if problems.empty?

        puts ""
        puts "missing: #{problems.join(", ")}"
        install_hints.each { |line| puts "  #{line}" }
        1
      end

      def self.doctor_spinel
        explicit = explicit_bin_dir
        unless explicit == ""
          report("spinel", usable?(explicit), "CYBERTRAIN_SPINEL_HOME -> #{explicit} (#{release_label(File.join(explicit, "spinel"))})")
          return
        end
        on_path = spinel_on_path
        if on_path != ""
          report("spinel", on_path?, "#{on_path} on PATH (#{release_label(on_path)})")
        end
        if usable?(bin_dir)
          report("spinel", true, "#{bin_dir} (managed, #{tag})")
        elsif on_path == ""
          puts "spinel    --   not installed; `cybertrain setup` builds #{tag} into #{prefix}"
        end
      end

      def self.release_label(spinel)
        release = release_at(spinel)
        release == "" ? "release unknown" : "release #{release}"
      end

      def self.report(name, ok, detail)
        puts "#{name.ljust(9)} #{ok ? "ok" : "MISSING"}   #{detail}"
      end

      # ---- shell helpers -------------------------------------------------

      def self.tmpdir
        dir = ENV["TMPDIR"].to_s
        dir == "" ? "/tmp" : dir
      end

      # stdout of a shell command (a pipeline or an `a || b` list too),
      # stripped; "" on failure.
      def self.sh_read(command)
        out = File.join(tmpdir, "cybertrain-sh-#{Process.pid}")
        system("(#{command}) > #{shell_quote(out)} 2>/dev/null")
        text = File.exist?(out) ? File.read(out).strip : ""
        File.delete(out) if File.exist?(out)
        text
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
