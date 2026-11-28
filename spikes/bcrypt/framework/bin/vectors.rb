# The pure-Ruby verifier (cybertrain/bcrypt.rb) compiled: published vectors,
# and the time per cost. docs/design.md D97.
require "cybertrain/bcrypt"

VECTORS = [
  ["", "$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s."],
  ["abcdefghijklmnopqrstuvwxyz", "$2a$06$.rCVZVOThsIa97pEDOxvGuRRgzG64bvtJ0938xuqzv18d3ZpQhstC"],
  ["U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"],
  ["0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored", "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"],
  ["\xff\xff\xa3", "$2b$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e"],
  ["\xff\xff\xa3", "$2a$05$/OK.fbVrR/bpIqNJ5ianF.nqd1wy.pTMdcvrRWxyiGL2eMz.2a85."]
]

VECTORS.each do |pair|
  puts "#{pair[1][0, 7]} #{Cybertrain::Bcrypt.verify?(pair[0], pair[1])} #{Cybertrain::Bcrypt.verify?(pair[0] + "x", pair[1])}"
end

# Same password, salt "abcdefghijklmnopqrstuu", costs 4 to 12 (made with
# libxcrypt's crypt(3) under CRuby).
TIMED = [
  "$2b$04$abcdefghijklmnopqrstuu7EJV7kdjBBQxyb0HjTh9KS7.Lah/6CG",
  "$2b$08$abcdefghijklmnopqrstuukS31SNuNEoGSYTPCfyZV8d2iX4qVmTa",
  "$2b$10$abcdefghijklmnopqrstuuGGgFFcYeueaAql8Z7U7CnCTRw4DR77W",
  "$2b$12$abcdefghijklmnopqrstuu0sDWleciW5uGBGYwxpcgAsh9WK4bWNy"
]
TIMED.each do |digest|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ok = Cybertrain::Bcrypt.verify?("correct horse battery staple", digest)
  ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).to_i
  puts "cost #{digest[4, 2]} #{ok} #{ms} ms"
end
