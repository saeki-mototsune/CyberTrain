# Columns (email_address, password_digest, admin, failed_attempts,
# locked_until), the Cybertrain::Model superclass and `sessions` (from
# the sessions table's foreign key) come from gen/models/user.rb,
# generated from db/schema.rb by `spin run gen`.
#
# Written by `cybertrain generate authentication`; it is yours to change.
# The password is hashed by Cybertrain::Password (PBKDF2-HMAC-SHA256) into
# password_digest; the plain text lives only in @password until the
# record is saved. `password=` and `authenticate` are what Rails'
# `has_secure_password` would define (Spinel cannot define methods at
# run time, so they are written out).
class User
  MIN_PASSWORD_LENGTH = 8

  validates :email_address, presence: true

  # Normalizes the address, refuses one that is not a single address
  # or is taken, and checks the password on a new record or whenever
  # one was given. Errors added here make the record invalid
  # (Cybertrain::Model.before_validation).
  before_validation do |user|
    user.email_address = User.normalize_email_address(user.email_address)
    user.validate_email_address_format
    user.validate_email_address_taken
    user.validate_password
  end

  # The address lowercased and trimmed: "  Ann@Example.COM " is
  # "ann@example.com", so a visitor signs in however they type it.
  def self.normalize_email_address(value)
    value.to_s.strip.downcase
  end

  # Whether value is one address: exactly one @, with text before and
  # after it, and no comma, whitespace, angle bracket or control
  # character. Cybertrain::Mailer reads "a@x.example,b@y.example" as two
  # recipients, so without this an account could hold two mailboxes and
  # have its mails (a confirmation link among them) sent to both. It
  # must also be an address the mailer sends to
  # (Cybertrain::Mailer.address_problem: plain ASCII, none of
  # ( ) [ ] ; : \ or ", within its length limits), so no account is
  # saved that could never be mailed. Some addresses the mail
  # standards allow (a quoted local part with a space or a comma in
  # it) are refused too.
  def self.email_address_format?(value)
    s = value.to_s
    n = s.bytesize
    at = -1
    i = 0
    while i < n
      b = s.getbyte(i)
      return false if b <= 32 || b == 127 || b == 44 || b == 60 || b == 62
      if b == 64
        return false if at >= 0

        at = i
      end
      i += 1
    end
    at > 0 && at < n - 1 && Cybertrain::Mailer.address_problem(s).empty?
  end

  # The user with this address and password, or nil. A missing address
  # and a locked account (locked?, while lockout is on) cost a password
  # verification too, against Cybertrain::Password.dummy_digest, and
  # answer nil whatever the password, as a wrong one does: the sign-in
  # form shows them all the wrong-password message. A wrong password
  # on an existing, unlocked account also writes its row once
  # (count_failed_attempt!), as Devise's lockable does; that one write
  # is the timing difference left between it and the other two, and it
  # is accepted. The right password clears the count.
  def self.authenticate_by(email_address:, password:)
    user = User.find_by(email_address: User.normalize_email_address(email_address))
    if user.nil? || (Cybertrain.config.auth_lockout_attempts > 0 && user.locked?)
      Cybertrain::Password.verify_serialized(password.to_s, Cybertrain::Password.dummy_digest)
      return nil
    end
    unless user.authenticate(password)
      user.count_failed_attempt!
      return nil
    end
    user.clear_failed_attempts!
    user
  end

  # The user a password_reset_token was made for, while it is valid against
  # that user's password and address now (password_reset_binding); nil for
  # any other token (a wrong, expired or spent one, or one made for another
  # user).
  def self.find_by_password_reset_token(token)
    text = token.to_s
    user = User.find_by(id: Cybertrain::Token.id_from(text))
    return nil if user.nil?
    return nil unless Cybertrain::Token.valid?(text, "password_reset", user.password_reset_binding)

    user
  end

  # The plain-text password given to `password=` in this request ("" when
  # none was), for the validations; never stored.
  def password
    plain = @password
    plain.nil? ? "" : plain
  end

  # Hashes the password into password_digest. A blank password clears
  # the digest, which `validate_password` reports.
  def password=(plain)
    text = plain.to_s
    @password = text
    self.password_digest = text.empty? ? "" : Cybertrain::Password.hash(text)
  end

  # What the sign-up form sends back a second time; nil until set, so a
  # form without the field is not asked to match.
  def password_confirmation
    @password_confirmation
  end

  def password_confirmation=(plain)
    @password_confirmation = plain.to_s
  end

  # Whether `plain` is this user's password. A digest hashed with fewer
  # iterations than Cybertrain::Password.iterations is rehashed and
  # saved on the way, so raising the cost in config/app.rb upgrades
  # everyone as they sign in (and, the digest being new, signs their
  # other browsers out once). verify_serialized runs one verification
  # at a time, so a burst of sign-ins does not hold every worker.
  def authenticate(plain)
    return false unless Cybertrain::Password.verify_serialized(plain.to_s, password_digest)

    if Cybertrain::Password.needs_rehash?(password_digest)
      self.password_digest = Cybertrain::Password.hash(plain.to_s)
      save
    end
    true
  end

  # Whether this user may see the admin pages (the Authentication
  # concern's require_admin): `./blog user admin EMAIL` sets it.
  def admin? = admin

  # Whether wrong passwords have locked the account for now
  # (count_failed_attempt!): authenticate_by refuses it until then,
  # unless lockout is off (auth_lockout_attempts 0), which also stops
  # enforcing a lock made before.
  def locked? = !locked_until.nil? && locked_until > Time.now

  # A wrong password: one more failed attempt, counted by the database
  # in one UPDATE that reads the row as it is (so sign-ins at the same
  # time all count). The attempt that reaches
  # Cybertrain.config.auth_lockout_attempts (10; 0 never locks) locks
  # the account for auth_lockout_period seconds (an hour) and starts
  # the count again, in the same statement.
  def count_failed_attempt!
    limit = Cybertrain.config.auth_lockout_attempts
    return nil if limit <= 0

    count = "failed_attempts = CASE WHEN failed_attempts + 1 >= ? THEN 0 ELSE failed_attempts + 1 END"
    lock = "locked_until = CASE WHEN failed_attempts + 1 >= ? THEN ? ELSE locked_until END"
    ends = Time.now + Cybertrain.config.auth_lockout_period
    User.where(id: id).update_all_sql(count + ", " + lock, [limit, limit, ends])
    nil
  end

  # No failed attempts and no lock: a successful sign-in calls it, and
  # so do `./blog user EMAIL PASSWORD` and a password reset
  # (PasswordsController#update). Writes only when there is something
  # to clear.
  def clear_failed_attempts!
    return nil if failed_attempts == 0 && locked_until.nil?

    update_columns(failed_attempts: 0, locked_until: nil)
    nil
  end

  # The token of a password reset link (PasswordsController): signed,
  # valid for 15 minutes from now, and bound to password_reset_binding,
  # so it stops working once the password or the address changes
  # (Cybertrain::Token).
  def password_reset_token(now = Time.now.to_i)
    Cybertrain::Token.issue("password_reset", id, 15 * 60, password_reset_binding, now)
  end

  # What a password reset token is bound to: the password and the address,
  # so a new password or a new address ends every link sent before (the
  # old address's mailbox keeps no way into the account).
  def password_reset_binding
    digest = password_digest.to_s
    address = email_address.to_s
    "#{digest}:#{address}"
  end

  # Public so the before_validation block above (which receives the
  # record, not an implicit self) can call them. Their messages come
  # from the dictionary of the current locale, as a validator's do.

  # An address saved before this check existed is left as it is, so
  # that account can still be reset and signed in to; a new or changed
  # one must be a single address (User.email_address_format?).
  def validate_email_address_format
    address = email_address.to_s
    return nil if address.empty? || User.email_address_format?(address)
    return nil if persisted? && User.where(id: id, email_address: address).exists?

    errors.add(:email_address, I18n.error_message("user", :email_address, :invalid))
    nil
  end

  def validate_email_address_taken
    address = email_address
    return nil if address.nil? || address.empty?

    taken = User.where(email_address: address).where_sql("id != ?", [id]).exists?
    errors.add(:email_address, I18n.error_message("user", :email_address, :taken)) if taken
    nil
  end

  def validate_password
    given = password
    if password_digest.to_s.empty?
      errors.add(:password, I18n.error_message("user", :password, :blank))
    elsif !given.empty? && given.size < MIN_PASSWORD_LENGTH
      errors.add(:password, I18n.error_message("user", :password, :too_short, { count: MIN_PASSWORD_LENGTH }))
    end
    confirmation = @password_confirmation
    if !confirmation.nil? && confirmation != given
      attribute = I18n.human_attribute_name("user", :password)
      errors.add(:password_confirmation, I18n.error_message("user", :password_confirmation, :confirmation, { attribute: attribute }))
    end
    nil
  end
end
