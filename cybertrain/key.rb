# Cybertrain::Key -- the text of a key given as a String or a Symbol
# (`params[:id]`, `session[:user_id]`, `where(title: ...)`, `t(:hello)`),
# without leaking memory under Spinel: read a key with
# Key.string_of(key), never key.to_s (spikes/NOTES.md rule 125).
#
# Key is defined in the HTTP layer, cybertrain/http/key.rb, since the
# layer's Params names its keys with it and the layer loads nothing
# outside cybertrain/http/ (docs/design.md D91). This file keeps the
# require path `cybertrain/key` for the rest of the framework.
require "cybertrain/http/key"
