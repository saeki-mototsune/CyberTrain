# Cybertrain::Bcrypt -- verifying the bcrypt digests Rails'
# `has_secure_password` wrote (`$2a$`, `$2b$`, `$2y$`), so that the users
# of a database taken over from Rails can sign in (docs/design.md D97).
# Only verification: new digests are Cybertrain::Password's PBKDF2 (D15),
# and Password.needs_rehash? is true for a bcrypt digest, so the generated
# `User#authenticate` stores a PBKDF2 digest the first time the password
# is verified.
#
# Plain Ruby, like Password and Crypto: EksBlowfish as Provos and
# Mazieres describe it, with the key setup of Solar Designer's
# crypt_blowfish, which the bcrypt gem bundles and which wrote the digests
# a Rails application holds. Each prefix is read as crypt_blowfish reads
# it: `$2b$` and `$2y$` are the corrected algorithm, `$2a$` the same plus
# crypt_blowfish's countermeasure for the old sign-extension bug (it
# changes the result only for some passwords with a 0xff byte), and `$2x$`
# (the bug itself) is refused. The password is read up to its first NUL
# byte and to 72 bytes, as the C library reads a C string: the bytes past
# 72 do not change a bcrypt digest. The cost is 4 to 31.
#
# Integers stay below 2**33 (a sum of two 32-bit words, masked at once),
# and every loop is a `while`, whose back edge is a safepoint: a cost-12
# digest takes some 4 million Blowfish blocks, and other requests keep
# being served while one is verified. Nothing is shared between calls but
# the read-only initial state, so verifications may run side by side.
require "cybertrain/crypto"

module Cybertrain
  # Verifies bcrypt digests. Cybertrain::Password.verify? calls it for a
  # digest that starts with `$2`; call it directly only to tell a bcrypt
  # digest from any other.
  # @api public
  module Bcrypt
    # bcrypt's own base64 alphabet (not RFC 4648's order).
    ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    # "OrpheanBeholderScryDoubt", the text bcrypt encrypts 64 times.
    MAGIC = "OrpheanBeholderScryDoubt"
    # The lowest and highest cost (log2 of the rounds) a digest may name.
    MIN_COST = 4
    MAX_COST = 31
    # Bytes of the password that count.
    MAX_KEY_BYTES = 72
    # A digest is "$2b$" + two cost digits + "$" + 22 salt + 31 hash characters.
    DIGEST_SIZE = 60
    MASK = 0xffffffff
    # Offsets of the four S-boxes after the 18 P words in one state Array.
    S0 = 18
    S1 = 274
    S2 = 530
    S3 = 786
    STATE_WORDS = 1042

    # The initial P-array and S-boxes (the hexadecimal digits of pi), as
    # 1042 big-endian words in hex: one String literal, decoded once at
    # load (a literal Array of 1042 Integers costs the C compiler more,
    # NOTES rule 101).
    INIT_HEX =
      "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89" \
      "452821e638d01377be5466cf34e90c6cc0ac29b7c97c50dd3f84d5b5b5470917" \
      "9216d5d98979fb1bd1310ba698dfb5ac2ffd72dbd01adfb7b8e1afed6a267e96" \
      "ba7c9045f12c7f9924a19947b3916cf70801f2e2858efc16636920d871574e69" \
      "a458fea3f4933d7e0d95748f728eb658718bcd5882154aee7b54a41dc25a59b5" \
      "9c30d5392af26013c5d1b023286085f0ca417918b8db38ef8e79dcb0603a180e" \
      "6c9e0e8bb01e8a3ed71577c1bd314b2778af2fda55605c60e65525f3aa55ab94" \
      "5748986263e8144055ca396a2aab10b6b4cc5c341141e8cea15486af7c72e993" \
      "b3ee1411636fbc2a2ba9c55d741831f6ce5c3e169b87931eafd6ba336c24cf5c" \
      "7a325381289586773b8f48986b4bb9afc4bfe81b6628219361d809ccfb21a991" \
      "487cac605dec8032ef845d5de98575b1dc262302eb651b8823893e81d396acc5" \
      "0f6d6ff383f442392e0b4482a484200469c8f04a9e1f9b5e21c66842f6e96c9a" \
      "670c9c61abd388f06a51a0d2d8542f68960fa728ab5133a36eef0b6c137a3be4" \
      "ba3bf0507efb2a98a1f1651d39af017666ca593e82430e888cee8619456f9fb4" \
      "7d84a5c33b8b5ebee06f75d885c12073401a449f56c16aa64ed3aa62363f7706" \
      "1bfedf72429b023d37d0d724d00a1248db0fead349f1c09b075372c980991b7b" \
      "25d479d8f6e8def7e3fe501ab6794c3b976ce0bd04c006bac1a94fb6409f60c4" \
      "5e5c9ec2196a246368fb6faf3e6c53b51339b2eb3b52ec6f6dfc511f9b30952c" \
      "cc814544af5ebd09bee3d004de334afd660f2807192e4bb3c0cba85745c8740f" \
      "d20b5f39b9d3fbdb5579c0bd1a60320ad6a100c6402c7279679f25fefb1fa3cc" \
      "8ea5e9f8db3222f83c7516dffd616b152f501ec8ad0552ab323db5fafd238760" \
      "53317b483e00df829e5c57bbca6f8ca01a87562edf1769dbd542a8f6287effc3" \
      "ac6732c68c4f5573695b27b0bbca58c8e1ffa35db8f011a010fa3d98fd2183b8" \
      "4afcb56c2dd1d35b9a53e479b6f84565d28e49bc4bfb9790e1ddf2daa4cb7e33" \
      "62fb1341cee4c6e8ef20cada36774c01d07e9efe2bf11fb495dbda4dae909198" \
      "eaad8e716b93d5a0d08ed1d0afc725e08e3c5b2f8e7594b78ff6e2fbf2122b64" \
      "8888b812900df01c4fad5ea0688fc31cd1cff191b3a8c1ad2f2f2218be0e1777" \
      "ea752dfe8b021fa1e5a0cc0fb56f74e818acf3d6ce89e299b4a84fe0fd13e0b7" \
      "7cc43b81d2ada8d9165fa2668095770593cc7314211a1477e6ad206577b5fa86" \
      "c75442f5fb9d35cfebcdaf0c7b3e89a0d6411bd3ae1e7e4900250e2d2071b35e" \
      "226800bb57b8e0af2464369bf009b91e5563911d59dfa6aa78c14389d95a537f" \
      "207d5ba202e5b9c5832603766295cfa911c819684e734a41b3472dca7b14a94a" \
      "1b5100529a532915d60f573fbc9bc6e42b60a47681e6740008ba6fb5571be91f" \
      "f296ec6b2a0dd915b6636521e7b9f9b6ff34052ec585566453b02d5da99f8fa1" \
      "08ba47996e85076a4b7a70e9b5b32944db75092ec4192623ad6ea6b049a7df7d" \
      "9cee60b88fedb266ecaa8c71699a17ff5664526cc2b19ee1193602a575094c29" \
      "a0591340e4183a3e3f54989a5b429d656b8fe4d699f73fd6a1d29c07efe830f5" \
      "4d2d38e6f0255dc14cdd20868470eb266382e9c6021ecc5e09686b3f3ebaefc9" \
      "3c9718146b6a70a1687f358452a0e286b79c5305aa5007373e07841c7fdeae5c" \
      "8e7d44ec5716f2b8b03ada37f0500c0df01c1f040200b3ffae0cf51a3cb574b2" \
      "25837a58dc0921bdd19113f97ca92ff69432477322f547013ae5e58137c2dadc" \
      "c8b576349af3dda7a94461460fd0030eecc8c73ea4751e41e238cd993bea0e2f" \
      "3280bba1183eb3314e548b384f6db9086f420d03f60a04bf2cb8129024977c79" \
      "5679b072bcaf89afde9a771fd9930810b38bae12dccf3f2e5512721f2e6b7124" \
      "501adde69f84cd877a5847187408da17bc9f9abce94b7d8cec7aec3adb851dfa" \
      "63094366c464c3d2ef1c18473215d908dd433b3724c2ba1612a14d432a65c451" \
      "50940002133ae4dd71dff89e10314e5581ac77d65f11199b043556f1d7a3c76b" \
      "3c11183b5924a509f28fe6ed97f1fbfa9ebabf2c1e153c6e86e34570eae96fb1" \
      "860e5e0a5a3e2ab3771fe71c4e3d06fa2965dcb999e71d0f803e89d65266c825" \
      "2e4cc9789c10b36ac6150eba94e2ea78a5fc3c531e0a2df4f2f74ea7361d2b3d" \
      "1939260f19c279605223a708f71312b6ebadfe6eeac31f66e3bc4595a67bc883" \
      "b17f37d1018cff28c332ddefbe6c5aa56558218568ab9802eecea50fdb2f953b" \
      "2aef7dad5b6e2f841521b62829076170ecdd4775619f151013cca830eb61bd96" \
      "0334fe1eaa0363cfb5735c904c70a239d59e9e0bcbaade14eecc86bc60622ca7" \
      "9cab5cabb2f3846e648b1eaf19bdf0caa02369b9655abb5040685a323c2ab4b3" \
      "319ee9d5c021b8f79b540b19875fa09995f7997e623d7da8f837889a97e32d77" \
      "11ed935f166812810e358829c7e61fd696dedfa17858ba9957f584a51b227263" \
      "9b83c3ff1ac24696cdb30aeb532e30548fd948e46dbc312858ebf2ef34c6ffea" \
      "fe28ed61ee7c3c735d4a14d9e864b7e342105d14203e13e045eee2b6a3aaabea" \
      "db6c4f15facb4fd0c742f442ef6abbb5654f3b1d41cd2105d81e799e86854dc7" \
      "e44b476a3d816250cf62a1f25b8d2646fc8883a0c1c7b6a37f1524c369cb7492" \
      "47848a0b5692b285095bbf00ad19489d1462b17423820e0058428d2a0c55f5ea" \
      "1dadf43e233f70613372f0928d937e41d65fecf16c223bdb7cde3759cbee7460" \
      "4085f2a7ce77326ea607808419f8509ee8efd85561d99735a969a7aac50c06c2" \
      "5a04abfc800bcadc9e447a2ec3453484fdd567050e1e9ec9db73dbd3105588cd" \
      "675fda79e3674340c5c43465713e38d83d28f89ef16dff20153e21e78fb03d4a" \
      "e6e39f2bdb83adf7e93d5a68948140f7f64c261c94692934411520f77602d4f7" \
      "bcf46b2ed4a20068d40824713320f46a43b7d4b7500061af1e39f62e97244546" \
      "14214f74bf8b88404d95fc1d96b591af70f4ddd366a02f45bfbc09ec03bd9785" \
      "7fac6dd031cb850496eb27b355fd3941da2547e6abca0a9a28507825530429f4" \
      "0a2c86dae9b66dfb68dc1462d7486900680ec0a427a18dee4f3ffea2e887ad8c" \
      "b58ce0067af4d6b6aace1e7cd3375fecce78a399406b2a4220fe9e35d9f385b9" \
      "ee39d7ab3b124e8b1dc9faf74b6d185626a36631eae397b23a6efa74dd5b4332" \
      "6841e7f7ca7820fbfb0af54ed8feb397454056acba48952755533a3a20838d87" \
      "fe6ba9b7d096954b55a867bca1159a58cca9296399e1db33a62a4a563f3125f9" \
      "5ef47e1c9029317cfdf8e80204272f7080bb155c05282ce395c11548e4c66d22" \
      "48c1133fc70f86dc07f9c9ee41041f0f404779a45d886e17325f51ebd59bc0d1" \
      "f2bcc18f41113564257b7834602a9c60dff8e8a31f636c1b0e12b4c202e1329e" \
      "af664fd1cad181156b2395e0333e92e13b240b62eebeb92285b2a20ee6ba0d99" \
      "de720c8c2da2f728d012784595b794fd647d0862e7ccf5f05449a36f877d48fa" \
      "c39dfd27f33e8d1e0a476341992eff743a6f6eabf4f8fd37a812dc60a1ebddf8" \
      "991be14cdb6e6b0dc67b55106d672c372765d43bdcd0e804f1290dc7cc00ffa3" \
      "b5390f92690fed0b667b9ffbcedb7d9ca091cf0bd9155ea3bb132f88515bad24" \
      "7b9479bf763bd6eb37392eb3cc1159798026e297f42e312d6842ada7c66a2b3b" \
      "12754ccc782ef11c6a124237b79251e706a1bbe64bfb63501a6b101811caedfa" \
      "3d25bdd8e2e1c3c9444216590a121386d90cec6ed5abea2a64af674eda86a85f" \
      "bebfe98864e4c3fe9dbc8057f0f7c08660787bf86003604dd1fd8346f6381fb0" \
      "7745ae04d736fccc83426b33f01eab71b08041873c005e5f77a057bebde8ae24" \
      "55464299bf582e614e58f48ff2ddfda2f474ef388789bdc25366f9c3c8b38e74" \
      "b475f25546fcd9b97aeb26618b1ddf84846a0e79915f95e2466e598e20b45770" \
      "8cd55591c902de4cb90bace1bb8205d011a862487574a99eb77f19b6e0a9dc09" \
      "662d09a1c4324633e85a1f0209f0be8c4a99a0251d6efe101ab93d1d0ba5a4df" \
      "a186f20f2868f169dcb7da83573906fea1e2ce9b4fcd7f5250115e01a70683fa" \
      "a002b5c40de6d0279af88c27773f8641c3604c0661a806b5f0177a28c0f586e0" \
      "006058aa30dc7d6211e69ed72338ea6353c2dd94c2c21634bbcbee5690bcb6de" \
      "ebfc7da1ce591d766f05e4094b7c018839720a3d7c927c2486e3725f724d9db9" \
      "1ac15bb4d39eb8fced54557808fca5b5d83d7cd34dad0fc41e50ef5eb161e6f8" \
      "a28514d96c51133c6fd5c7e756e14ec4362abfceddc6c837d79a323492638212" \
      "670efa8e406000e03a39ce37d3faf5cfabc277375ac52d1b5cb0679e4fa33742" \
      "d382274099bc9bbed5118e9dbf0f7315d62d1c7ec700c47bb78c1b6b21a19045" \
      "b26eb1be6a366eb45748ab2fbc946e79c6a376d26549c2c8530ff8ee468dde7d" \
      "d5730a1d4cd04dc62939bbdba9ba4650ac9526e8be5ee304a1fad5f06a2d519a" \
      "63ef8ce29a86ee22c089c2b843242ef6a51e03aa9cf2d0a483c061ba9be96a4d" \
      "8fe51550ba645bd62826a2f9a73a3ae14ba99586ef5562e9c72fefd3f752f7da" \
      "3f046f6977fa0a5980e4a91587b086019b09e6ad3b3ee593e990fd5a9e34d797" \
      "2cf0b7d9022b8b5196d5ac3a017da67dd1cf3ed67c7d2d281f9f25cfadf2b89b" \
      "5ad6b4725a88f54ce029ac71e019a5e647b0acfded93fa9be8d3c48d283b57cc" \
      "f8d5662979132e28785f0191ed756055f7960e44e3d35e8c15056dd488f46dba" \
      "03a161250564f0bdc3eb9e153c9057a297271aeca93a072a1b3f6d9b1e6321f5" \
      "f59c66fb26dcf3197533d928b155fdf5035634828aba3cbb28517711c20ad9f8" \
      "abcc5167ccad925f4de817513830dc8e379d58629320f991ea7a90c2fb3e7bce" \
      "5121ce64774fbe32a8b6e37ec3293d4648de53696413e680a2ae0810dd6db224" \
      "69852dfd09072166b39a460a6445c0dd586cdecf1c20c8ae5bbef7dd1b588d40" \
      "ccd2017f6bb4e3bbdda26a7e3a59ff453e350a44bcb4cdd572eacea8fa6484bb" \
      "8d6612aebf3c6f47d29be463542f5d9eaec2771bf64e6370740e0d8de75b1357" \
      "f8721671af537d5d4040cb084eb4e2cc34d2466a0115af84e1b0042895983a1d" \
      "06b89fb4ce6ea0486f3f3b823520ab82011a1d4b277227f8611560b1e7933fdc" \
      "bb3a792b344525bda08839e151ce794b2f32c9b7a01fbac9e01cc87ebcc7d1f6" \
      "cf0111c3a1e8aac71a908749d44fbd9ad0dadecbd50ada380339c32ac6913667" \
      "8df9317ce0b12b4ff79e59b743f5bb3af2d519ff27d9459cbf97222c15e6fc2a" \
      "0f91fc719b941525fae59361ceb69cebc2a8645912baa8d1b6c1075ee3056a0c" \
      "10d25065cb03a442e0ec6e0e1698db3b4c98a0be3278e9649f1f9532e0d392df" \
      "d3a0342b8971f21e1b0a74414ba3348cc5be7120c37632d8df359f8d9b992f2e" \
      "e60b6f470fe3f11de54cda541edad891ce6279cfcd3e7e6f1618b166fd2c1d05" \
      "848fd2c5f6fb2299f523f357a632762393a8353156cccd02acf081625a75ebb5" \
      "6e16369788d273ccde96629281b949d04c50901b71c65614e6c6c7bd327a140a" \
      "45e1d006c3f27b9ac9aa53fd62a80f00bb25bfe235bdd2f671126905b2040222" \
      "b6cbcf7ccd769c2b53113ec01640e3d338abbd602547adf0ba38209cf746ce76" \
      "77afa1c52075606085cbfe4e8ae88dd87aaaf9b04cf9aa7e1948c25c02fb8a8c" \
      "01c36ae4d6ebe1f990d4f869a65cdea03f09252dc208e69fb74e6132ce77e25b" \
      "578fdfe33ac372e6"

    # The 1042 words of INIT_HEX.
    def self.initial_words
      words = [0]
      words.clear
      i = 0
      while i < STATE_WORDS
        words << INIT_HEX[i * 8, 8].to_s.to_i(16)
        i += 1
      end
      words
    end

    # Read-only after load: every verification copies it.
    @initial_state = Bcrypt.initial_words

    def self.initial_state
      @initial_state
    end

    # Whether the text has the shape of a bcrypt digest this module
    # verifies: `$2a$`, `$2b$` or `$2y$`, a cost of MIN_COST to MAX_COST,
    # and 53 characters of the bcrypt alphabet.
    # @param digest [String, nil]
    # @return [Boolean]
    # @api public
    def self.digest?(digest)
      return false if digest.nil?

      text = digest.to_s
      return false unless text.bytesize == DIGEST_SIZE
      return false unless text.getbyte(0) == 36 && text.getbyte(1) == 50 && text.getbyte(3) == 36 && text.getbyte(6) == 36

      minor = text.getbyte(2)
      return false unless minor == 97 || minor == 98 || minor == 121

      cost = Bcrypt.cost_of(text)
      return false if cost < MIN_COST || cost > MAX_COST

      i = 7
      while i < DIGEST_SIZE
        return false if Bcrypt.sextet(text.getbyte(i)) < 0

        i += 1
      end
      true
    end

    # The cost a digest names (two decimal digits), or -1.
    def self.cost_of(text)
      tens = text.getbyte(4) - 48
      ones = text.getbyte(5) - 48
      return -1 if tens < 0 || tens > 9 || ones < 0 || ones > 9

      tens * 10 + ones
    end

    # Whether the password matches the bcrypt digest, compared in constant
    # time. False for anything digest? refuses.
    # @param password [String]
    # @param digest [String, nil]
    # @return [Boolean]
    # @api public
    def self.verify?(password, digest)
      return false unless Bcrypt.digest?(digest)

      text = digest.to_s
      Crypto.secure_compare(Bcrypt.hash_with(password.to_s, text), text)
    end

    # The 60-character digest of `password` under the setting (prefix,
    # cost and salt) of `digest`, which digest? has accepted: what
    # crypt_blowfish answers for crypt(password, digest).
    def self.hash_with(password, digest)
      text = digest.to_s
      salt = Bcrypt.decode_salt(text)
      safety = text.getbyte(2) == 97
      key = Bcrypt.key_bytes(password.to_s)
      expanded = [0]
      expanded.clear
      initial = [0]
      initial.clear
      Bcrypt.set_key(key, safety, expanded, initial)
      state = Bcrypt.eks_setup(salt, expanded, initial, Bcrypt.cost_of(text))
      words = Bcrypt.encrypt_magic(state)
      out = text[0, 28].to_s
      # The salt's last character carries 2 bits; crypt_blowfish writes
      # it back with the other 4 cleared.
      out << ALPHABET[Bcrypt.sextet(text.getbyte(28)) & 0x30, 1].to_s
      out << Bcrypt.encode_words(words, 23)
      out
    end

    # The value 0..63 of a character of ALPHABET, or -1.
    def self.sextet(byte)
      return 0 if byte == 46
      return 1 if byte == 47
      return byte - 63 if byte >= 65 && byte <= 90
      return byte - 69 if byte >= 97 && byte <= 122
      return byte + 6 if byte >= 48 && byte <= 57

      -1
    end

    # The 16 salt bytes of characters 7..28, as four big-endian words.
    def self.decode_salt(text)
      bytes = [0]
      bytes.clear
      i = 7
      while bytes.size < 16
        c1 = Bcrypt.sextet(text.getbyte(i))
        c2 = Bcrypt.sextet(text.getbyte(i + 1))
        bytes << (((c1 << 2) | ((c2 & 0x30) >> 4)) & 0xff)
        break if bytes.size >= 16

        c3 = Bcrypt.sextet(text.getbyte(i + 2))
        bytes << ((((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2)) & 0xff)
        c4 = Bcrypt.sextet(text.getbyte(i + 3))
        bytes << ((((c3 & 0x03) << 6) | c4) & 0xff)
        i += 4
      end
      salt = [0]
      salt.clear
      w = 0
      while w < 4
        salt << ((bytes[w * 4] << 24) | (bytes[w * 4 + 1] << 16) | (bytes[w * 4 + 2] << 8) | bytes[w * 4 + 3])
        w += 1
      end
      salt
    end

    # The password's bytes up to its first NUL, at most MAX_KEY_BYTES, and
    # the terminating 0 crypt_blowfish cycles through.
    def self.key_bytes(password)
      plain = password.to_s
      bytes = [0]
      bytes.clear
      i = 0
      while i < plain.bytesize && bytes.size < MAX_KEY_BYTES
        b = plain.getbyte(i)
        break if b == 0

        bytes << b
        i += 1
      end
      bytes << 0
      bytes
    end

    # crypt_blowfish's BF_set_key: 18 words cycled out of the key bytes
    # into `expanded`, and `initial` = the initial P-array XOR them, with
    # bit 16 of initial[0] flipped when the `$2a$` countermeasure applies
    # (the buggy sign-extended reading would have given the same words).
    def self.set_key(key, safety, expanded, initial)
      init = Bcrypt.initial_state
      sign = 0
      diff = 0
      pos = 0
      i = 0
      while i < 18
        right = 0
        bugged = 0
        j = 0
        while j < 4
          b = key[pos]
          right = ((right << 8) | b) & MASK
          extended = b >= 128 ? (b | 0xffffff00) : b
          bugged = ((bugged << 8) | extended) & MASK
          sign |= bugged & 0x80 if j > 0
          pos = b == 0 ? 0 : pos + 1
          j += 1
        end
        diff |= right ^ bugged
        expanded << right
        initial << (init[i] ^ right)
        i += 1
      end
      diff |= diff >> 16
      diff &= 0xffff
      diff += 0xffff
      sign = (sign << 9) & ~diff & 0x10000
      initial[0] = initial[0] ^ sign if safety
      nil
    end

    # One Blowfish encryption of (l, r) under `state`, written to
    # state[at] and state[at + 1].
    def self.encipher(state, l, r, at)
      left = l ^ state[0]
      right = r
      i = 1
      while i < 17
        x = left
        f = (((state[S0 + (x >> 24)] + state[S1 + ((x >> 16) & 0xff)]) & MASK) ^ state[S2 + ((x >> 8) & 0xff)])
        right ^= ((f + state[S3 + (x & 0xff)]) & MASK) ^ state[i]
        x = right
        f = (((state[S0 + (x >> 24)] + state[S1 + ((x >> 16) & 0xff)]) & MASK) ^ state[S2 + ((x >> 8) & 0xff)])
        left ^= ((f + state[S3 + (x & 0xff)]) & MASK) ^ state[i + 1]
        i += 2
      end
      state[at] = right ^ state[17]
      state[at + 1] = left
      nil
    end

    # Re-encrypts the whole state in a chain from (0, 0), XORing the four
    # salt words in turn into each block when `salted` (the first, salted
    # expansion); state[STATE_WORDS, 2] holds the chain between blocks.
    def self.expand(state, salt, salted)
      l = 0
      r = 0
      k = 0
      at = 0
      while at < STATE_WORDS
        if salted
          l ^= salt[k]
          r ^= salt[k + 1]
          k = k == 0 ? 2 : 0
        end
        Bcrypt.encipher(state, l, r, at)
        l = state[at]
        r = state[at + 1]
        at += 2
      end
      nil
    end

    # EksBlowfishSetup: the salted expansion under `initial`, then
    # 2**cost rounds of expanding with the key and with the salt.
    def self.eks_setup(salt, expanded, initial, cost)
      state = Bcrypt.initial_state.dup
      i = 0
      while i < 18
        state[i] = initial[i]
        i += 1
      end
      Bcrypt.expand(state, salt, true)
      rounds = 1 << cost
      n = 0
      while n < rounds
        i = 0
        while i < 18
          state[i] = state[i] ^ expanded[i]
          i += 1
        end
        Bcrypt.expand(state, salt, false)
        i = 0
        while i < 18
          state[i] = state[i] ^ salt[i & 3]
          i += 1
        end
        Bcrypt.expand(state, salt, false)
        n += 1
      end
      state
    end

    # The six words of MAGIC, each pair encrypted 64 times.
    def self.encrypt_magic(state)
      state << 0
      state << 0
      words = [0]
      words.clear
      i = 0
      while i < 6
        l = Bcrypt.magic_word(i)
        r = Bcrypt.magic_word(i + 1)
        n = 0
        while n < 64
          Bcrypt.encipher(state, l, r, STATE_WORDS)
          l = state[STATE_WORDS]
          r = state[STATE_WORDS + 1]
          n += 1
        end
        words << l
        words << r
        i += 2
      end
      words
    end

    # Word i of MAGIC, big-endian.
    def self.magic_word(i)
      w = 0
      j = 0
      while j < 4
        w = (w << 8) | MAGIC.getbyte(i * 4 + j)
        j += 1
      end
      w
    end

    # The first `count` big-endian bytes of the words, in bcrypt's base64.
    def self.encode_words(words, count)
      bytes = [0]
      bytes.clear
      i = 0
      while i < count
        bytes << ((words[i >> 2] >> (24 - 8 * (i & 3))) & 0xff)
        i += 1
      end
      out = +""
      i = 0
      while i < count
        c1 = bytes[i]
        out << ALPHABET[c1 >> 2, 1].to_s
        c1 = (c1 & 3) << 4
        if i + 1 >= count
          out << ALPHABET[c1, 1].to_s
          break
        end
        c2 = bytes[i + 1]
        out << ALPHABET[c1 | (c2 >> 4), 1].to_s
        c1 = (c2 & 0x0f) << 2
        if i + 2 >= count
          out << ALPHABET[c1, 1].to_s
          break
        end
        c2 = bytes[i + 2]
        out << ALPHABET[c1 | (c2 >> 6), 1].to_s
        out << ALPHABET[c2 & 0x3f, 1].to_s
        i += 3
      end
      out
    end
  end
end
