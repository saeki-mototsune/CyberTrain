# Columns (email_address, password_digest), the Cybertrain::Model
# superclass and `sessions` (from the sessions table's foreign key) come
# from gen/models/user.rb, generated from db/schema.rb by `spin run gen`.
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

  # Normalizes the address, refuses a taken one, and checks the password
  # on a new record or whenever one was given. Errors added here make
  # the record invalid (Cybertrain::Model.before_validation).
  before_validation do |user|
    user.email_address = User.normalize_email_address(user.email_address)
    user.validate_email_address_taken
    user.validate_password
  end

  # The address lowercased and trimmed: "  Ann@Example.COM " is
  # "ann@example.com", so a visitor signs in however they type it.
  def self.normalize_email_address(value)
    value.to_s.strip.downcase
  end

  # The user with this address and password, or nil. A missing address
  # costs a verification too (against Cybertrain::Password.dummy_digest),
  # so the response time does not say which of the two was wrong.
  def self.authenticate_by(email_address:, password:)
    user = User.find_by(email_address: User.normalize_email_address(email_address))
    if user.nil?
      Cybertrain::Password.verify_serialized(password.to_s, Cybertrain::Password.dummy_digest)
      return nil
    end
    user.authenticate(password) ? user : nil
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

  # Public so the before_validation block above (which receives the
  # record, not an implicit self) can call them.

  def validate_email_address_taken
    address = email_address
    return nil if address.nil? || address.empty?

    taken = User.where(email_address: address).where_sql("id != ?", [id]).exists?
    errors.add(:email_address, "has already been taken") if taken
    nil
  end

  def validate_password
    given = password
    if password_digest.to_s.empty?
      errors.add(:password, "can't be blank")
    elsif !given.empty? && given.size < MIN_PASSWORD_LENGTH
      errors.add(:password, "is too short (minimum is #{MIN_PASSWORD_LENGTH} characters)")
    end
    confirmation = @password_confirmation
    errors.add(:password_confirmation, "doesn't match Password") if !confirmation.nil? && confirmation != given
    nil
  end
end
