# `./blog user EMAIL [PASSWORD]` (cybertrain generate authentication --invite-only):
# creates the user with this address, or sets the password of the one
# that has it (which signs that user's browsers out: their sessions'
# password key no longer matches; and clears a lockout, User#locked?).
# Without PASSWORD it is read from
# standard input, one line, so that it stays out of `ps` and the shell
# history:
#
#   ./blog user ann@example.com          # type it, then Enter (it is echoed)
#   printf '%s' "$PASSWORD" | ./blog user ann@example.com
#
# `./blog user admin EMAIL` makes that user an admin (User#admin?, which
# the Authentication concern's require_admin asks for: the jobs page),
# `./blog user unadmin EMAIL` makes them an ordinary user again.
#
# Registered with Cybertrain::Main.command, which connects the database
# first. Required by bin/blog.rb, which also calls UserCommand.warn_if_no_user before serving.
# Written by the generator; it is yours to change.
module UserCommand
  USAGE = "usage: ./blog user EMAIL [PASSWORD] (without PASSWORD, it is read from standard input) | ./blog user admin EMAIL | ./blog user unadmin EMAIL"

  # The exit status: 0 when the user was created, updated or made an
  # admin or not, 1 for bad arguments, an empty password, an unknown
  # address (admin, unadmin) or a record that does not validate.
  def self.run(argv)
    if !argv.empty? && (argv[0] == "admin" || argv[0] == "unadmin")
      if argv.size != 2
        puts USAGE
        return 1
      end
      return UserCommand.grant_admin(argv[1], argv[0] == "admin")
    end
    if argv.empty? || argv.size > 2 || argv[0].start_with?("-")
      puts USAGE
      return 1
    end
    password = argv.size == 2 ? argv[1] : UserCommand.read_password
    if password.empty?
      puts "error: the password is empty"
      return 1
    end

    address = User.normalize_email_address(argv[0])
    found = User.find_by(email_address: address)
    created = found.nil?
    user = found.nil? ? User.new(email_address: address) : found
    user.password = password
    unless user.save
      user.errors.full_messages.each { |message| puts "error: #{message}" }
      return 1
    end
    user.clear_failed_attempts!
    puts created ? "created #{address}" : "updated #{address}"
    0
  end

  # `user admin EMAIL` (granted) or `user unadmin EMAIL`: prints what
  # admin_change did and answers the exit status.
  def self.grant_admin(email, granted)
    line = UserCommand.admin_change(email, granted)
    puts line
    line.start_with?("error: ") ? 1 : 0
  end

  # Sets the admin flag of the user with this address, who must exist,
  # and answers the line to print: "admin ann@example.com",
  # "unadmin ann@example.com" or "error: ...".
  def self.admin_change(email, granted)
    address = User.normalize_email_address(email)
    found = User.find_by(email_address: address)
    return "error: no user #{address}" if found.nil?

    found.admin = granted
    return "error: #{found.errors.full_messages.join(", ")}" unless found.save

    granted ? "admin #{address}" : "unadmin #{address}"
  end

  # One line of standard input, with a prompt when it is a terminal.
  def self.read_password
    if STDIN.tty?
      STDOUT.print("Password: ")
      STDOUT.flush
    end
    line = STDIN.gets
    UserCommand.password_from(line.nil? ? "" : line)
  end

  # The text without one trailing newline ("\n" or "\r\n"), which a
  # terminal or `echo` adds. Anything else, spaces too, is the password.
  def self.password_from(text)
    s = text.to_s
    s = s[0, s.size - 1].to_s if s.end_with?("\n")
    s = s[0, s.size - 1].to_s if s.end_with?("\r")
    s
  end

  # Called by bin/blog.rb before the server boots: a WARN line while no
  # user exists, which is while /setup is open, with the page's
  # one-time token (SetupController.setup_token, this process's own).
  # Says nothing when the users table is not there yet (`./blog
  # migrate` comes first).
  def self.warn_if_no_user
    Cybertrain.logger.warn("no user exists yet: run ./blog user EMAIL, or open /setup?token=#{SetupController.setup_token} from this machine") if UserCommand.no_user?
    nil
  end

  # Connects for the question only: Application#boot connects the
  # server's own pool afterwards.
  def self.no_user?
    begin
      Cybertrain::DB.connect(Cybertrain.config.database_path, size: 1)
      !User.all.exists?
    rescue Cybertrain::DB::Error
      false
    ensure
      Cybertrain::DB.disconnect
    end
  end
end

Cybertrain::Main.command("user", "EMAIL [PASSWORD] | admin EMAIL | unadmin EMAIL: create a user or set its password, or grant or revoke admin") do |argv|
  UserCommand.run(argv)
end
