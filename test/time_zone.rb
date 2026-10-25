require "tmpdir"
require "cybertrain/test"
require "cybertrain/time_zone"

# Cybertrain::TimeZone: the civil-time helpers, TZif parsing (version 1 and
# 2+ files built byte by byte below, so the snapshot does not depend on the
# machine's tz database), the POSIX TZ footer rules, zone name validation,
# the cache, and the system's Asia/Tokyo when it is installed (with a
# synthetic stand-in when it is not, so the assertions and the snapshot are
# the same either way). The expected instants were checked against glibc's
# own reading of the same TZ strings. Plain Ruby, no FFI: the snapshot comes
# from CRuby or the compiled binary alike.

TZ = Cybertrain::TimeZone
ROOT = Dir.mktmpdir("cybertrain-time-zone")
ZONEINFO = "#{ROOT}/zoneinfo"

def rm_tree(path)
  if File.symlink?(path)
    File.delete(path)
  elsif File.directory?(path)
    Dir.children(path).each { |child| rm_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  rm_tree(ROOT)
end

# --- a TZif writer (RFC 8536), byte by byte ------------------------------

# Bytes come from byteslices of a table, never n.chr appended to a UTF-8
# buffer (test/blob_store.rb does the same). Every append goes through
# put8/put_str: under Spinel a `buf << "\n"` in the method that also hands
# buf to a helper wrote to a copy, and the helpers' bytes were lost (the
# result held only the footer).
BYTE_TABLE = (0..255).map { |n| n.chr }.join.b

def put8(buf, v)
  buf << BYTE_TABLE.byteslice(v & 255, 1)
end

def put_str(buf, text)
  buf << text
end

def put32(buf, v)
  u = v < 0 ? v + 4_294_967_296 : v
  put8(buf, u >> 24)
  put8(buf, u >> 16)
  put8(buf, u >> 8)
  put8(buf, u)
end

def put64(buf, v)
  hi = v.div(4_294_967_296)
  put32(buf, hi)
  put32(buf, v - hi * 4_294_967_296)
end

def put_header(buf, version, isut, isstd, leap, timecnt, typecnt, charcnt)
  put_str(buf, "TZif")
  put8(buf, version)
  15.times { put8(buf, 0) }
  put32(buf, isut)
  put32(buf, isstd)
  put32(buf, leap)
  put32(buf, timecnt)
  put32(buf, typecnt)
  put32(buf, charcnt)
end

def char_count(abbrs)
  total = 0
  abbrs.each { |a| total += a.bytesize + 1 }
  total
end

# The data block: transitions, their types, ttinfos, the abbreviations
# (one NUL-terminated string per type), one leap-second record when wide,
# and the standard/wall and UT/local indicators (all zero).
def put_block(buf, width, times, idxs, utoffs, dsts, abbrs)
  times.each { |t| width == 8 ? put64(buf, t) : put32(buf, t) }
  idxs.each { |i| put8(buf, i) }
  at = 0
  utoffs.each_index do |i|
    put32(buf, utoffs[i])
    put8(buf, dsts[i])
    put8(buf, at)
    at += abbrs[i].bytesize + 1
  end
  abbrs.each do |a|
    put_str(buf, a)
    put8(buf, 0)
  end
  if width == 8
    put64(buf, 78_796_800)
    put32(buf, 1)
  end
  utoffs.size.times { put8(buf, 0) }
  utoffs.size.times { put8(buf, 0) }
end

# version 0: a version 1 file (32-bit data only, no footer). Otherwise a
# minimal 32-bit block (one UTC type), then the 64-bit block and the footer.
def tzif(version, times, idxs, utoffs, dsts, abbrs, footer)
  buf = "".b
  if version.zero?
    put_header(buf, 0, 0, 0, 0, times.size, utoffs.size, char_count(abbrs))
    put_block(buf, 4, times, idxs, utoffs, dsts, abbrs)
    return buf
  end
  put_header(buf, version, 1, 1, 0, 0, 1, 4)
  put_block(buf, 4, Array.new(0) { 0 }, Array.new(0) { 0 }, [0], [0], ["UTC"])
  put_header(buf, version, utoffs.size, utoffs.size, 1, times.size, utoffs.size, char_count(abbrs))
  put_block(buf, 8, times, idxs, utoffs, dsts, abbrs)
  put_str(buf, "\n")
  put_str(buf, footer)
  put_str(buf, "\n")
  buf
end

def write_zone(name, bytes)
  path = "#{ZONEINFO}/#{name}"
  dir = File.dirname(path)
  make_dirs(dir)
  File.binwrite(path, bytes)
end

def make_dirs(dir)
  return if File.directory?(dir)

  make_dirs(File.dirname(dir))
  Dir.mkdir(dir)
end

BIG_BANG = -576_460_752_303_423_488

# America/New_York as a "slim" file: the 2025 transitions only, then
# EST5EDT,M3.2.0,M11.1.0. Type 0 (LMT) applies before the first transition.
def slim_new_york
  tzif(50, [BIG_BANG, 1_741_503_600, 1_762_063_200], [2, 1, 2],
       [-17_762, -14_400, -18_000], [0, 1, 0], ["LMT", "EDT", "EST"], "EST5EDT,M3.2.0,M11.1.0")
end

# A zone with no transitions, so the footer decides every instant; type 0
# ("BAD", +00:10) is what a footer that does not parse falls back to.
def footer_zone(tz_string)
  TZ.parse_tzif("Test/Footer", tzif(50, Array.new(0) { 0 }, Array.new(0) { 0 }, [600], [0], ["BAD"], tz_string))
end

def civil(y, mo, d, h, mi, s)
  TZ.civil_to_epoch(y, mo, d, h, mi, s)
end

# --- tests ---------------------------------------------------------------

test "civil time helpers count proleptic Gregorian days from 1970" do
  assert_equal [1970, 1, 1, 0, 0, 0, 4], TZ.epoch_to_civil(0)
  assert_equal [1969, 12, 31, 23, 59, 59, 3], TZ.epoch_to_civil(-1)
  assert_equal [1969, 7, 20, 20, 17, 40, 0], TZ.epoch_to_civil(-14_182_940)
  assert_equal 951_825_600, civil(2000, 2, 29, 12, 0, 0)
  assert_equal [2000, 2, 29, 12, 0, 0, 2], TZ.epoch_to_civil(951_825_600)
  assert_equal(-11_670_912_000, civil(1600, 3, 1, 0, 0, 0))
  assert_equal [1600, 3, 1, 0, 0, 0, 3], TZ.epoch_to_civil(-11_670_912_000)
  # Out-of-range fields roll over.
  assert_equal civil(2027, 1, 1, 0, 0, 0), civil(2026, 13, 1, 0, 0, 0)
  assert_equal civil(2026, 2, 28, 0, 0, 0), civil(2026, 3, 0, 0, 0, 0)
  assert_equal civil(2026, 3, 1, 0, 0, 0), civil(2026, 2, 28, 24, 0, 0)
  assert_equal civil(2025, 12, 1, 0, 0, 0), civil(2026, 0, 1, 0, 0, 0)
end

test "UTC is built in and needs no file" do
  assert TZ::UTC.found?
  assert TZ.find("UTC").equal?(TZ::UTC)
  assert_equal "UTC", TZ::UTC.zone_name
  assert_equal 0, TZ::UTC.utc_offset_at(1_792_886_400)
  assert_equal "UTC", TZ::UTC.abbreviation_at(1_792_886_400)
  refute TZ::UTC.dst_at?(1_792_886_400)
  assert_equal 1_792_886_400, TZ::UTC.local_to_utc(1_792_886_400)
  assert_equal 1_792_886_400, TZ::UTC.utc_to_local(1_792_886_400)
end

test "valid_name? accepts relative names and refuses anything that could leave the directory" do
  assert TZ.valid_name?("Asia/Tokyo")
  assert TZ.valid_name?("America/Argentina/Buenos_Aires")
  assert TZ.valid_name?("Etc/GMT+9")
  assert TZ.valid_name?("Etc/GMT-14")
  assert TZ.valid_name?("EST5EDT")
  assert TZ.valid_name?("a.b")
  refute TZ.valid_name?("")
  refute TZ.valid_name?("/etc/passwd")
  refute TZ.valid_name?("../etc/passwd")
  refute TZ.valid_name?("Asia/../../etc/passwd")
  refute TZ.valid_name?("Asia/./Tokyo")
  refute TZ.valid_name?("Asia//Tokyo")
  refute TZ.valid_name?("Asia/")
  refute TZ.valid_name?(".")
  refute TZ.valid_name?("..")
  refute TZ.valid_name?("...")
  refute TZ.valid_name?("Asia/Tokyo\n")
  refute TZ.valid_name?("Asia Tokyo")
  refute TZ.valid_name?("Asia\\Tokyo")
  refute TZ.valid_name?("Asia/Tôkyô")
  refute TZ.valid_name?("a" * 256)
end

test "a slim version 2 file: 64-bit transitions, then the POSIX footer" do
  write_zone("Test/New_York", slim_new_york)
  ENV["TZDIR"] = ZONEINFO
  before = TZ.cached_count
  ny = TZ.find("Test/New_York")
  assert ny.found?
  refute ny.unknown?
  assert_equal "Test/New_York", ny.zone_name
  assert_equal 3, ny.transition_count
  assert ny.footer?
  assert_equal before + 1, TZ.cached_count
  assert TZ.find("Test/New_York").equal?(ny)
  assert_equal before + 1, TZ.cached_count
  # Before the first transition (a 64-bit negative time): type 0.
  assert_equal(-17_762, ny.utc_offset_at(BIG_BANG - 1))
  assert_equal "LMT", ny.abbreviation_at(BIG_BANG - 1)
  # From the transition table.
  assert_equal(-18_000, ny.utc_offset_at(0))
  assert_equal(-18_000, ny.utc_offset_at(1_741_503_599))
  assert_equal(-14_400, ny.utc_offset_at(1_741_503_600))
  assert ny.dst_at?(1_741_503_600)
  assert_equal "EDT", ny.abbreviation_at(1_741_503_600)
  assert_equal(-14_400, ny.utc_offset_at(1_762_063_199))
  assert_equal(-18_000, ny.utc_offset_at(1_762_063_200))
  # After the last one: the footer's rule (2026: March 8, November 1).
  assert_equal(-18_000, ny.utc_offset_at(1_772_953_199))
  assert_equal "EST", ny.abbreviation_at(1_772_953_199)
  refute ny.dst_at?(1_772_953_199)
  assert_equal(-14_400, ny.utc_offset_at(1_772_953_200))
  assert_equal "EDT", ny.abbreviation_at(1_772_953_200)
  assert ny.dst_at?(1_772_953_200)
  assert_equal(-14_400, ny.utc_offset_at(1_793_512_799))
  assert_equal(-18_000, ny.utc_offset_at(1_793_512_800))
  assert_equal(-14_400, ny.utc_offset_at(civil(2100, 7, 1, 0, 0, 0)))
  assert_equal(-18_000, ny.utc_offset_at(civil(2100, 1, 1, 0, 0, 0)))
end

test "local_to_utc and utc_to_local, with deterministic gaps and overlaps" do
  ENV["TZDIR"] = ZONEINFO
  nyc = TZ.find("Test/New_York")
  # An ordinary wall time, there and back.
  assert_equal 1_782_910_800, nyc.local_to_utc(civil(2026, 7, 1, 9, 0, 0))
  assert_equal civil(2026, 7, 1, 9, 0, 0), nyc.utc_to_local(1_782_910_800)
  # 02:30 on a spring-forward day does not exist: read with the offset
  # before the jump (EST), it is 07:30 UTC, which the wall clock shows as
  # 03:30 EDT. The same from the table (2025) and from the footer (2026).
  gap = nyc.local_to_utc(civil(2026, 3, 8, 2, 30, 0))
  assert_equal 1_772_953_200 + 1800, gap
  assert_equal [2026, 3, 8, 3, 30, 0, 0], TZ.epoch_to_civil(nyc.utc_to_local(gap))
  assert_equal 1_741_503_600 + 1800, nyc.local_to_utc(civil(2025, 3, 9, 2, 30, 0))
  # 01:30 on a fall-back day happens twice: the earlier (EDT) instant.
  overlap = nyc.local_to_utc(civil(2026, 11, 1, 1, 30, 0))
  assert_equal 1_793_512_800 - 1800, overlap
  assert_equal "EDT", nyc.abbreviation_at(overlap)
  assert_equal 1_762_063_200 - 1800, nyc.local_to_utc(civil(2025, 11, 2, 1, 30, 0))
  # Either side of the transitions converts both ways.
  assert_equal 1_772_953_200 - 1, nyc.local_to_utc(civil(2026, 3, 8, 1, 59, 59))
  assert_equal 1_772_953_200, nyc.local_to_utc(civil(2026, 3, 8, 3, 0, 0))
  assert_equal 1_793_512_800 + 5400, nyc.local_to_utc(civil(2026, 11, 1, 2, 30, 0))
end

test "a version 1 file: 32-bit transitions and no footer" do
  write_zone("Test/V1", tzif(0, [-700_000_000, -690_000_000], [1, 0], [32_400, 36_000], [0, 1], ["JST", "JDT"], ""))
  ENV["TZDIR"] = ZONEINFO
  v1 = TZ.find("Test/V1")
  assert v1.found?
  assert_equal 2, v1.transition_count
  refute v1.footer?
  assert_equal 32_400, v1.utc_offset_at(-700_000_001)
  assert_equal 36_000, v1.utc_offset_at(-700_000_000)
  assert_equal "JDT", v1.abbreviation_at(-690_000_001)
  assert v1.dst_at?(-690_000_001)
  assert_equal 32_400, v1.utc_offset_at(-690_000_000)
  # No footer: the last transition's type holds for ever.
  assert_equal 32_400, v1.utc_offset_at(4_000_000_000)
  assert_equal "JST", v1.abbreviation_at(4_000_000_000)
end

test "version 3 and 4 files are read like version 2" do
  write_zone("Test/V3", tzif(51, Array.new(0) { 0 }, Array.new(0) { 0 }, [12_600], [0], ["+0330"], "<+0330>-3:30"))
  write_zone("Test/V4", tzif(52, [0], [0], [-3600], [0], ["-01"], "<-01>1"))
  ENV["TZDIR"] = ZONEINFO
  v3 = TZ.find("Test/V3")
  assert v3.found?
  assert_equal 12_600, v3.utc_offset_at(1_792_886_400)
  assert_equal "+0330", v3.abbreviation_at(1_792_886_400)
  v4 = TZ.find("Test/V4")
  assert v4.found?
  assert_equal(-3600, v4.utc_offset_at(1_792_886_400))
  assert_equal "-01", v4.abbreviation_at(1_792_886_400)
end

test "POSIX footers: M, J and zero-based rules, negative and 26-hour times" do
  jst = footer_zone("JST-9")
  assert jst.footer?
  assert_equal 32_400, jst.utc_offset_at(0)
  assert_equal 32_400, jst.utc_offset_at(4_000_000_000)
  assert_equal "JST", jst.abbreviation_at(0)
  refute jst.dst_at?(0)
  # Southern hemisphere: DST from October to April, ending at 03:00.
  syd = footer_zone("AEST-10AEDT,M10.1.0,M4.1.0/3")
  assert_equal 39_600, syd.utc_offset_at(1_775_318_399)
  assert_equal "AEDT", syd.abbreviation_at(1_775_318_399)
  assert_equal 36_000, syd.utc_offset_at(1_775_318_400)
  assert_equal 36_000, syd.utc_offset_at(1_791_043_199)
  assert_equal 39_600, syd.utc_offset_at(1_791_043_200)
  assert syd.dst_at?(civil(2027, 1, 1, 0, 0, 0))
  # A negative rule time (America/Nuuk since 2023).
  nuuk = footer_zone("<-02>2<-01>,M3.5.0/-1,M10.5.0/0")
  assert_equal(-7200, nuuk.utc_offset_at(1_774_745_999))
  assert_equal(-3600, nuuk.utc_offset_at(1_774_746_000))
  assert_equal "-01", nuuk.abbreviation_at(1_774_746_000)
  assert_equal(-3600, nuuk.utc_offset_at(1_792_889_999))
  assert_equal(-7200, nuuk.utc_offset_at(1_792_890_000))
  # A rule time past 24 hours (Asia/Jerusalem: Thursday 26:00).
  jer = footer_zone("IST-2IDT,M3.4.4/26,M10.5.0")
  assert_equal 7200, jer.utc_offset_at(1_774_569_599)
  assert_equal 10_800, jer.utc_offset_at(1_774_569_600)
  assert_equal 10_800, jer.utc_offset_at(1_792_882_799)
  assert_equal 7200, jer.utc_offset_at(1_792_882_800)
  # Jn never counts February 29; n does (2028 is a leap year).
  julian = footer_zone("<+01>-1<+02>,J60/0,J300/0")
  assert_equal 3600, julian.utc_offset_at(1_835_477_999)
  assert_equal 7200, julian.utc_offset_at(1_835_478_000)
  assert_equal "+02", julian.abbreviation_at(1_835_478_000)
  zero_based = footer_zone("<+01>-1<+02>,59/0,299/0")
  assert_equal 3600, zero_based.utc_offset_at(1_835_391_599)
  assert_equal 7200, zero_based.utc_offset_at(1_835_391_600)
  assert_equal 7200, zero_based.utc_offset_at(1_856_123_999)
  assert_equal 3600, zero_based.utc_offset_at(1_856_124_000)
  # DST without a rule: the US rules.
  us = footer_zone("EST5EDT")
  assert_equal(-18_000, us.utc_offset_at(1_772_953_199))
  assert_equal(-14_400, us.utc_offset_at(1_772_953_200))
  # DST all year (RFC 8536's example), across New Year too.
  always = footer_zone("EST5EDT4,0/0,J365/25")
  assert_equal(-14_400, always.utc_offset_at(civil(2026, 7, 1, 0, 0, 0)))
  assert_equal(-14_400, always.utc_offset_at(1_798_758_000))
  assert_equal(-14_400, always.utc_offset_at(civil(2027, 1, 1, 2, 0, 0)))
  assert_equal(-14_400, always.utc_offset_at(civil(2027, 1, 1, 5, 0, 0)))
  assert_equal "EDT", always.abbreviation_at(civil(2027, 1, 1, 5, 0, 0))
end

test "a footer that does not parse is ignored: the last type holds" do
  ["EST", "5EST", "EST25", "<AB>1", "EST5EDT,M13.1.0,M11.1.0", "EST5EDT,M3.2.0", "EST5EDT,J0,J365",
   "EST5EDT,M3.2.0,M11.1.0/168", "EST5EDT,M3.2.0,M11.1.0x"].each do |bad|
    broken = footer_zone(bad)
    assert broken.found?
    refute broken.footer?
    assert_equal 600, broken.utc_offset_at(1_792_886_400)
    assert_equal "BAD", broken.abbreviation_at(1_792_886_400)
  end
end

test "malformed TZif bytes give an unknown zone that behaves as UTC" do
  good = slim_new_york
  assert TZ.parse_tzif("Test/Good", good).found?
  samples = [
    "",
    "TZif",
    "XZif".b + good.byteslice(4, good.bytesize - 4).to_s,
    good.byteslice(0, good.bytesize - 40).to_s,
    good.byteslice(0, 60).to_s,
    tzif(50, [100], [3], [0], [0], ["UTC"], ""),
    tzif(50, [100, 50], [0, 0], [0], [0], ["UTC"], ""),
    tzif(50, [100], [0], [0], [2], ["UTC"], ""),
    tzif(50, Array.new(0) { 0 }, Array.new(0) { 0 }, Array.new(0) { 0 }, Array.new(0) { 0 }, Array.new(0) { "" }, ""),
    tzif(0, [100], [1], [0], [0], ["UTC"], ""),
  ]
  samples.each do |bytes|
    damaged = TZ.parse_tzif("Test/Damaged", bytes)
    refute damaged.found?
    assert damaged.unknown?
    assert_equal "Test/Damaged", damaged.zone_name
    assert_equal 0, damaged.utc_offset_at(1_792_886_400)
    assert_equal 1_792_886_400, damaged.local_to_utc(1_792_886_400)
  end
end

test "find refuses names outside the directory, directories and non-TZif files, uncached" do
  write_zone("outside", slim_new_york)
  File.write("#{ZONEINFO}/Test/notes.txt", "not a zone\n")
  ENV["TZDIR"] = "#{ZONEINFO}/Test"
  assert TZ.find("New_York").found?
  count = TZ.cached_count
  refute TZ.find("../outside").found?
  refute TZ.find("#{ZONEINFO}/outside").found?
  refute TZ.find("/New_York").found?
  refute TZ.find("./New_York").found?
  refute TZ.find("notes.txt").found?
  refute TZ.find("Missing/Zone").found?
  ENV["TZDIR"] = ROOT
  refute TZ.find("zoneinfo").found?
  missing = TZ.find("Nope/Zone")
  assert missing.unknown?
  assert_equal "Nope/Zone", missing.zone_name
  assert_equal 0, missing.utc_offset_at(1_792_886_400)
  assert_equal "UTC", missing.abbreviation_at(1_792_886_400)
  assert_equal count, TZ.cached_count
end

test "find from several threads keeps one zone per name" do
  write_zone("Par/A", slim_new_york)
  write_zone("Par/B", tzif(50, Array.new(0) { 0 }, Array.new(0) { 0 }, [32_400], [0], ["JST"], "JST-9"))
  write_zone("Par/C", tzif(0, [0], [0], [3600], [0], ["CET"], ""))
  ENV["TZDIR"] = ZONEINFO
  start_count = TZ.cached_count
  workers = []
  4.times do
    workers << Thread.new do
      20.times do
        TZ.find("Par/A")
        TZ.find("Par/B")
        TZ.find("Par/C")
      end
    end
  end
  workers.each(&:join)
  assert_equal start_count + 3, TZ.cached_count
  assert TZ.find("Par/A").equal?(TZ.find("Par/A"))
  assert_equal(-18_000, TZ.find("Par/A").utc_offset_at(0))
  assert_equal 32_400, TZ.find("Par/B").utc_offset_at(0)
  assert_equal 3600, TZ.find("Par/C").utc_offset_at(0)
  assert_equal start_count + 3, TZ.cached_count
end

test "Asia/Tokyo from the system zoneinfo (a stand-in where none is installed)" do
  ENV["TZDIR"] = ""
  tokyo = TZ::UTC
  if File.file?("#{TZ::DEFAULT_DIR}/Asia/Tokyo")
    tokyo = TZ.find("Asia/Tokyo")
  else
    tokyo = TZ.parse_tzif("Asia/Tokyo", tzif(50, Array.new(0) { 0 }, Array.new(0) { 0 }, [32_400], [0], ["JST"], "JST-9"))
  end
  assert tokyo.found?
  assert_equal "Asia/Tokyo", tokyo.zone_name
  assert_equal 32_400, tokyo.utc_offset_at(1_792_886_400)
  assert_equal 32_400, tokyo.utc_offset_at(4_000_000_000)
  assert_equal "JST", tokyo.abbreviation_at(1_792_886_400)
  assert_equal "JST", tokyo.abbreviation_at(4_000_000_000)
  refute tokyo.dst_at?(1_792_886_400)
  # 09:00 on 25 October 2026 in Tokyo is midnight UTC.
  assert_equal 1_792_886_400, tokyo.local_to_utc(civil(2026, 10, 25, 9, 0, 0))
  assert_equal [2026, 10, 25, 9, 0, 0, 0], TZ.epoch_to_civil(tokyo.utc_to_local(1_792_886_400))
end

Cybertrain::Test.run!
