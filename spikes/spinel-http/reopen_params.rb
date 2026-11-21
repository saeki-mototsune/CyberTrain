# spinel-http phase 1, Task 1, step 4: strong parameters added to the HTTP
# layer's Params by reopening the class in a second file. A record, not a
# test.
#
# Run (2026-11-21, Linux x86_64, gcc 13.3.0, 4 vCPU, from spikes/spinel-http/;
# binaries kept outside the package, rule 98). The fork is the pinned
# 2026.11.15.7033 (a2f3bfaa) on PATH; upstream is matz/spinel's release
# 2026.10.25 (2814693f), built with toolchain.rb's four steps into
# ~/.spinel-upstream/2026.10.25. spin builds only bin/*.rb, so `spin run`
# does not reach a top-level record; `spin flags` gives the package's flags
# (the fork's says --strict-require, upstream's --require-gate, the same
# flag under another name):
#   spinel $(spin flags) reopen_params.rb -o $TMPDIR/reopen_params && $TMPDIR/reopen_params
#   PATH=$U:$PATH spinel $(PATH=$U:$PATH spin flags) reopen_params.rb -o $TMPDIR/r-up && $TMPDIR/r-up
# (reopen_params/core.rb is the HTTP layer's file, required through the
# package's -I.) Output, the same under the fork, upstream (4 s compile) and
# CRuby 3.3.6 (`ruby -I . reopen_params.rb`; CRuby 3.3 writes `=>` without
# spaces in Hash#inspect):
#   a[b][c] read back: 1
#   permit on the nested child: {"c" => "1"}
#   permit with a nested filter: {"b" => {"c" => "1"}, "t" => ["x", "y"]}
#   require then permit: {"c" => "1", "d" => "2"}
#   permit at the top: {"z" => "top", "a" => {}}
#   ParameterMissing rescued: param is missing or the value is empty: missing
# Verdict: PASS under both. Children built by `Params.new` inside the core
# file answer the methods the second file adds, nested filters recurse
# through `child.permitted_by`, and an error class nested in the reopened
# class is raised and rescued by its qualified name.
require "reopen_params/core"

# cybertrain's half: reopen Params beside the HTTP layer's file, adding
# permit (cybertrain/params.rb's permitted_by, unchanged), require and an
# error class.
class Params
  class ParameterMissing < StandardError
  end

  def permit(*keys)
    permitted_by(keys)
  end

  def require(key)
    k = key.to_s
    child = @children[k]
    if child.nil?
      msg = "param is missing or the value is empty: #{k}"
      raise ParameterMissing, msg
    end
    child
  end

  def self.permitted_hash
    h = { "" => [nil, 0, 0.0, "", true][0] }
    h.delete("")
    h
  end

  def self.copy_strings(list)
    out = []
    list.each { |s| out << s.dup }
    out
  end

  def permitted_by(filters)
    out = Params.permitted_hash
    i = 0
    while i < filters.length
      f = filters[i]
      case f
      when Hash
        names = f.keys
        j = 0
        while j < names.length
          name = names[j]
          k = name.to_s
          inner = f[name]
          case inner
          when Array
            if inner.empty?
              list = @lists[k]
              out[k] = Params.copy_strings(list) unless list.nil?
            else
              child = @children[k]
              out[k] = child.permitted_by(inner) unless child.nil?
            end
          end
          j += 1
        end
      else
        k = f.to_s
        out[k] = @values[k] if @values.key?(k)
      end
      i += 1
    end
    out
  end
end

params = SpikeQuery.parse("a[b][c]=1&a[b][d]=2&a[t][]=x&a[t][]=y&z=top")
puts "a[b][c] read back: #{params.nested("a").nested("b")["c"]}"
puts "permit on the nested child: #{params.nested("a").nested("b").permit(:c).inspect}"
puts "permit with a nested filter: #{params.nested("a").permit(b: [:c], t: []).inspect}"
puts "require then permit: #{params.require(:a).require(:b).permit(:c, :d).inspect}"
puts "permit at the top: #{params.permit(:z, a: [:t]).inspect}"
begin
  params.require(:missing)
rescue Params::ParameterMissing => e
  puts "ParameterMissing rescued: #{e.message}"
end
