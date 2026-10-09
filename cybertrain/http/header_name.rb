module Cybertrain
  # Case-insensitive header-name helpers that allocate nothing in the common
  # case. Header lookups used to `downcase` both the wanted name and every key
  # they compared it with, a String each, several times per request. Both
  # helpers give the same answers as those `downcase` comparisons: they
  # compare ASCII bytes directly and fall back to `downcase` (which also folds
  # non-ASCII letters) as soon as a byte outside ASCII shows up.
  module HeaderName
    # name.downcase, without the copy when name has no ASCII capital and no
    # byte outside ASCII.
    def self.lower(name)
      i = 0
      n = name.bytesize
      while i < n
        b = name.getbyte(i)
        return name.downcase if (b >= 65 && b <= 90) || b >= 128
        i += 1
      end
      name
    end

    # a.downcase == b.downcase.
    def self.same?(a, b)
      n = a.bytesize
      return a.downcase == b.downcase if n != b.bytesize && !(HeaderName.ascii?(a) && HeaderName.ascii?(b))
      return false if n != b.bytesize

      i = 0
      while i < n
        x = a.getbyte(i)
        y = b.getbyte(i)
        return a.downcase == b.downcase if x >= 128 || y >= 128

        if x != y
          x += 32 if x >= 65 && x <= 90
          y += 32 if y >= 65 && y <= 90
          return false if x != y
        end
        i += 1
      end
      true
    end

    def self.ascii?(s)
      i = 0
      n = s.bytesize
      while i < n
        return false if s.getbyte(i) >= 128
        i += 1
      end
      true
    end
  end
end
