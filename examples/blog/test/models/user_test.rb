# The User model's address check (cybertrain generate authentication).
require "test_helper"

class UserTest < ActiveSupport::TestCase
  # User.email_address_format?: one address, whatever the mail
  # standards allow beyond that.
  test "an address is one address: one @, nothing around it that splits it" do
    ["ann@example.com", "ann+news@example.com", "ann.lee+news@mail.example.co.jp", "a@b", "o'brien@example.com"].each do |address|
      assert User.email_address_format?(address), address
    end
    ["", "ann", "@example.com", "ann@", "a@b@example.com", "ann@example.com,eve@evil.example",
     "ann@example.com eve@evil.example", "ann @example.com", "<ann@example.com>", "Ann <ann@example.com>",
     "ann@example.com\n", "ann@exa\tmple.com", "\"ann lee\"@example.com",
     "ann@example.com\u00A0", "ann\u3000@example.com", "ann\u0085@example.com", "ann@exa\u2028mple.com",
     "ann;x@example.com", "ann(x)@example.com", "ann@[example].com", "ann:x@example.com"].each do |address|
      refute User.email_address_format?(address), address
    end
  end

  # An address saved before the check existed (an older release's) is
  # not checked again: its owner can still reset the password.
  test "an address saved before the format check still saves" do
    user = users(:one)
    user.update_columns(email_address: "one@example.com,old@example.com")
    kept = User.find(user.id)
    kept.password = "an0ther-s3cr3t"
    assert kept.save
    kept.email_address = "one@example.com,new@example.com"
    refute kept.save
    assert_includes kept.errors.full_messages, "Email address is invalid"
  end
end
