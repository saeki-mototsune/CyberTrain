# Step 3b: cybertrain/params.rb's shape, reopening Cybertrain::Params (an alias
# of SpinelHttp::Params) in a second file, over children the first file built.
require "reopen_shape/by_alias"

def check(label, ok)
  puts((ok ? "PASS " : "FAIL ") + label)
end

p = Cybertrain::Query.parse("top")
check("permit at the top", p.permit("a") == {"a" => "top"})
check("permit on the nested child", p.nested("b").permit("c", "d") == {"c" => "1", "d" => "2"})
check("require then permit", p.require("b").permit("c") == {"c" => "1"})
check("SpinelHttp::Params sees the method", SpinelHttp::Params.new.permit("a") == {})
check("Cybertrain::Params.equal?(SpinelHttp::Params)", Cybertrain::Params.equal?(SpinelHttp::Params))
check("Params.max_page via alias", Cybertrain::Params.max_page == 10_000)
Cybertrain::Params.max_page = 5
check("max_page= via alias seen via real name", SpinelHttp::Params.max_page == 5)

ok = false
begin
  p.require("missing")
rescue Cybertrain::Params::ParameterMissing => e
  ok = (e.message == "missing")
end
check("ParameterMissing rescued via Cybertrain::Params::ParameterMissing", ok)
ok = false
begin
  p.require("missing")
rescue SpinelHttp::Params::ParameterMissing => e
  ok = true
end
check("ParameterMissing rescued via SpinelHttp::Params::ParameterMissing", ok)
