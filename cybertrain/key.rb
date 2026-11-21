# Cybertrain::Key -- the text of a key given as a String or a Symbol
# (`params[:id]`, `session[:user_id]`, `where(title: ...)`, `t(:hello)`),
# without leaking memory under Spinel.
#
# Under Spinel, `Symbol#to_s` answers a new frozen String at every call,
# and a frozen heap String is immortal there (the collector pins it, as it
# pins a literal): every `sym.to_s` on a request path kept about 110 bytes
# for the life of the process, which is what made examples/blog's server
# grow by about 1 to 4 KB per request (NOTES rule 125). `Symbol#name`
# answers one frozen String per Symbol, made at its first call and the same
# object afterwards, under CRuby as under Spinel.
#
# So a framework method that takes a key as a String or a Symbol reads it
# with Key.string_of(key), never key.to_s. The answer is frozen for a
# Symbol (as Spinel's to_s already was), the String itself for a String,
# and to_s of anything else (an Integer key, a model), which is an
# ordinary collectable String.
#
# Plain Ruby with no requires: every part of the framework may require it.
module Cybertrain
  module Key
    # @param key [String, Symbol, Object]
    # @return [String]
    def self.string_of(key)
      key.is_a?(Symbol) ? key.name : key.to_s
    end
  end
end
