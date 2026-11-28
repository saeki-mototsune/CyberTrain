# roundhouse's spinel-bcrypt v0.1.1 compiled (docs/design.md D97): the same
# vectors and costs as ../framework/bin/vectors.rb, then two threads
# hashing at once.
require "bcrypt"

VECTORS = [
  ["", "$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s."],
  ["abcdefghijklmnopqrstuvwxyz", "$2a$06$.rCVZVOThsIa97pEDOxvGuRRgzG64bvtJ0938xuqzv18d3ZpQhstC"],
  ["U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"],
  ["0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored", "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"],
  ["\xff\xff\xa3", "$2b$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e"],
  ["\xff\xff\xa3", "$2a$05$/OK.fbVrR/bpIqNJ5ianF.nqd1wy.pTMdcvrRWxyiGL2eMz.2a85."]
]

VECTORS.each do |pair|
  d = BCrypt::Password.new(pair[1])
  puts "#{pair[1][0, 7]} #{d == pair[0]} #{d == pair[0] + "x"}"
end

TIMED = [
  "$2b$04$abcdefghijklmnopqrstuu7EJV7kdjBBQxyb0HjTh9KS7.Lah/6CG",
  "$2b$08$abcdefghijklmnopqrstuukS31SNuNEoGSYTPCfyZV8d2iX4qVmTa",
  "$2b$10$abcdefghijklmnopqrstuuGGgFFcYeueaAql8Z7U7CnCTRw4DR77W",
  "$2b$12$abcdefghijklmnopqrstuu0sDWleciW5uGBGYwxpcgAsh9WK4bWNy"
]
TIMED.each do |digest|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ok = BCrypt::Password.new(digest) == "correct horse battery staple"
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).to_i
  puts "cost #{digest[4, 2]} #{ok} #{ms} ms"
end

# Two threads hash at cost 4, 200 times each: one the right password of
# A, the other a wrong one. sp_bcrypt.c returns every result in one
# static (not thread-local) buffer, so a thread can read the other's.
A = "$2b$04$abcdefghijklmnopqrstuu7EJV7kdjBBQxyb0HjTh9KS7.Lah/6CG"
threads = []
threads << Thread.new do
  n = 0
  bad = 0
  while n < 200
    bad += 1 unless BCrypt::Engine.hash_secret("correct horse battery staple", A) == A
    n += 1
  end
  bad
end
threads << Thread.new do
  n = 0
  bad = 0
  while n < 200
    bad += 1 if BCrypt::Engine.hash_secret("wrong", A) == A
    n += 1
  end
  bad
end
puts "right password refused: #{threads[0].value}"
puts "wrong password accepted: #{threads[1].value}"
