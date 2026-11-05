module Cybertrain
  module DB
    # A bind value that goes to SQLite as a BLOB: `Connection#bind` sends
    # its bytes with `sqlite3_bind_blob` and their byte length, so a NUL byte
    # or a byte above 127 is stored as it is. Every other String binds as
    # TEXT, which is why a binary column's value is wrapped in one (the
    # generated models' `to_row` does it for `t.binary` columns).
    #
    # Reading needs no wrapper: a BLOB cell comes back from
    # `Connection#execute` as a String holding exactly the stored bytes
    # ({Cast.binary} narrows such a cell to a String, "" for NULL).
    # @example
    #   bytes = File.binread("logo.png")
    #   Cybertrain::DB.with do |c|
    #     c.execute("INSERT INTO images (data) VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])
    #   end
    # @api public
    class Blob
      # The bytes to store. A distinctive name, not `bytes` or `data`
      # (spikes/NOTES.md rules 10 and 34).
      # @return [String]
      # @api public
      attr_reader :blob_bytes

      # @param bytes [String] the raw bytes (any encoding; only the bytes count)
      # @api public
      def initialize(bytes)
        @blob_bytes = bytes
      end

      # `bytes` wrapped in a Blob, or nil for nil (a NULL in a nullable
      # binary column): what a generated model's `to_row` binds.
      # @param bytes [String, nil]
      # @return [Blob, nil]
      def self.wrap(bytes)
        return nil if bytes.nil?

        Blob.new(bytes.to_s)
      end
    end
  end
end
