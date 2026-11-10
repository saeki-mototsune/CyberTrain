# Phase 4a spike, item 5 (spec section 12), first half: the asset digest
# in the gen program. Shaped like an application's bin/gen.rb (the
# generator, a config/routes.rb, Runner reachable), it writes a 1 MB file,
# reads it back with File.binread and takes Digest::SHA256.digest of it;
# the asset digest of plan decision 2 is the hex of the first 4 bytes. A
# record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase4/):
#   spinel $(spin flags) asset_digest.rb -o /tmp/asset_digest && /tmp/asset_digest
#   ruby -I../.. asset_digest.rb
# Output, compiled (29 s to compile, a 2.0 MB binary; one cloud vCPU):
#   read 1048576 bytes
#   sha256: 06b7bbfb7824aa03382051691630eb26de85102d1b08a81e907ec0744cd8a286
#   asset digest: 06b7bbfb
#   binread 1.36 ms, digest 0.79 ms
#   binread + digest, mean of 10: 1.08 ms
#   routes: 9
# CRuby 3.3.6 prints the same digest lines, with
#   binread 0.6 ms, digest 6.38 ms
#   binread + digest, mean of 10: 5.04 ms
require "cybertrain/generator"
require "digest"

Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end

ASSET_PATH = "/tmp/phase4_asset_digest.bin"
SIZE = 1024 * 1024

def write_asset
  chunk = +""
  i = 0
  while i < 4096
    chunk << ((i * 31 + 7) % 256).chr
    i += 1
  end
  data = +""
  data << chunk while data.bytesize < SIZE
  File.binwrite(ASSET_PATH, data)
  nil
end

def hex(bytes, count)
  s = bytes.to_s
  out = +""
  i = 0
  while i < count
    out << format("%02x", s.getbyte(i).to_i)
    i += 1
  end
  out
end

if ARGV[0] == "--gen"
  exit(Cybertrain::Gen::Runner.run(".", ARGV.drop(1)))
end

write_asset
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
bytes = File.binread(ASSET_PATH)
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
digest = Digest::SHA256.digest(bytes)
t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "read #{bytes.bytesize} bytes"
puts "sha256: #{Digest::SHA256.hexdigest(bytes)}"
puts "asset digest: #{hex(digest, 4)}"
puts "binread #{((t1 - t0) * 1000).round(2)} ms, digest #{((t2 - t1) * 1000).round(2)} ms"
runs = 10
t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n = 0
while n < runs
  Digest::SHA256.digest(File.binread(ASSET_PATH))
  n += 1
end
t4 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "binread + digest, mean of #{runs}: #{((t4 - t3) * 1000 / runs).round(2)} ms"
puts "routes: #{Cybertrain::Routes.specs.size}"
File.delete(ASSET_PATH)
