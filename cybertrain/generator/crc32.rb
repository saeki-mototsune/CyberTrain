# Gen::Crc32 -- the CRC-32 of zlib (reflected polynomial 0xEDB88320), in
# pure Ruby, so gen gives a fixture label the id Rails gives it
# (`ActiveRecord::FixtureSet.identify`: `Zlib.crc32(label) % (2**30 - 1)`)
# without linking zlib into bin/gen.
#
# Spinel rules followed: 62 (the text's bytes are read through a fresh
# local), 9 (the table starts as a seeded Integer Array).
module Cybertrain
  module Gen
    module Crc32
      # The 256-entry table, built on first use.
      @table = Array.new(0) { 0 }

      # The CRC-32 of the text's bytes: crc32("123456789") is 0xCBF43926.
      def self.crc32(text)
        s = text.to_s
        table = Crc32.crc_table
        crc = 0xFFFFFFFF
        i = 0
        n = s.bytesize
        while i < n
          crc = table[(crc ^ s.getbyte(i).to_i) & 0xFF] ^ (crc >> 8)
          i += 1
        end
        crc ^ 0xFFFFFFFF
      end

      # Rails' id for a fixture label: crc32(label) % (2**30 - 1).
      def self.fixture_id(label)
        Crc32.crc32(label) % 1_073_741_823
      end

      def self.crc_table
        return @table unless @table.empty?

        k = 0
        while k < 256
          c = k
          bit = 0
          while bit < 8
            c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            bit += 1
          end
          @table << c
          k += 1
        end
        @table
      end
    end
  end
end
