module Outer
  module Inner
    class Inner; end
    class Oops < StandardError; end
    def self.boom = raise(Oops, "x")
  end
end
module Outer
  module User
    def self.run
      s = "none"
      begin
        Inner.boom
      rescue Inner::Oops => e
        s = "oops"
      rescue StandardError => e
        s = "std"
      end
      s
    end
  end
end
puts Outer::User.run
