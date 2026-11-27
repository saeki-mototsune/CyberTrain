# The MySQL adapter: the Connection the pool opens (cybertrain/db/mysql/
# connection.rb, with the driver it is built on: wire, packet, url,
# handshake, auth, protocol, result and the statement cache), and the TLS
# layer, since ssl_mode=verify, the default, connects over TLS
# (cybertrain/net/tls: Spinel's openssl package), and DB::Adapter
# (cybertrain/db/mysql/dialect.rb; the Dialect comes in a later task).
# cybertrain/db/base plus this file is a program's database layer on
# MySQL, as cybertrain/db is on SQLite.
require "cybertrain/net/tls"
require "cybertrain/db/mysql/connection"
require "cybertrain/db/mysql/dialect"
