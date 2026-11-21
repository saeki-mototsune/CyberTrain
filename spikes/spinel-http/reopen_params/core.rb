# The HTTP layer's half of reopen_params.rb (spinel-http phase 1, Task 1,
# step 4): the nested-params structure Query fills, trimmed from
# cybertrain/params.rb, with no strong parameters. Not a program.
class Params
  def initialize
    @values = {}
    @lists = {}
    @children = {}
  end

  def [](key)
    @values[key.to_s]
  end

  def list(key)
    arr = @lists[key.to_s]
    arr.nil? ? [] : arr
  end

  def nested(key)
    @children[key.to_s] || Params.new
  end

  def set_value(key, value)
    k = key.to_s
    @lists.delete(k)
    @children.delete(k)
    @values[k] = value
  end

  def add_list_value(key, value)
    k = key.to_s
    @values.delete(k)
    @children.delete(k)
    @lists[k] = [] unless @lists.key?(k)
    @lists[k] << value
  end

  # Children are built here, inside the HTTP layer, with Params.new.
  def child!(key)
    k = key.to_s
    @values.delete(k)
    @lists.delete(k)
    unless @children.key?(k)
      @children[k] = Params.new
    end
    @children[k]
  end

  def set_path(path, value)
    node = self
    i = 0
    done = false
    until done
      remaining = path.length - i
      if remaining <= 0
        done = true
      elsif remaining == 1
        node.set_value(path[i], value)
        done = true
      elsif remaining == 2 && path[i + 1] == ""
        node.add_list_value(path[i], value)
        done = true
      else
        node = node.child!(path[i])
        i += 1
      end
    end
    nil
  end
end

# Query.parse's shape: split each key on brackets, set_path into a fresh
# Params. No percent-decoding; the spike's input has none.
module SpikeQuery
  def self.split_key(name)
    key = name.to_s
    first = key.byteindex("[")
    return [key] if first.nil?

    parts = [key.byteslice(0, first).to_s]
    pos = first
    while pos < key.bytesize
      close = key.byteindex("]", pos)
      return [key] if close.nil?

      parts << key.byteslice(pos + 1, close - pos - 1).to_s
      pos = close + 1
    end
    parts
  end

  def self.parse(str)
    params = Params.new
    str.split("&").each do |pair|
      eq = pair.index("=")
      next if eq.nil?

      params.set_path(SpikeQuery.split_key(pair[0, eq]), pair[eq + 1, pair.length - eq - 1])
    end
    params
  end
end
