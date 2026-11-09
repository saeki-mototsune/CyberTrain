# Cybertrain::GzipFFI -- the gzip inflater behind Request#decoded_body, bound
# to the system zlib (-lz, zlib.h) through Spinel FFI.
#
# Spinel's own `zlib` package inflates in one shot into a buffer that grows
# without bound, so it cannot refuse a body that is small on the wire and
# huge once inflated (a "zip bomb": DEFLATE expands up to about 1032 times,
# and a lying gzip trailer hides the size). This module streams through
# zlib's inflate() with a ceiling on the output: the request is refused the
# moment the inflated bytes pass the limit. The C buffer never exceeds
# limit + 1 bytes; a body that passes is then copied into a Ruby String
# before the buffer is freed, so the peak for an accepted body is its
# compressed size plus twice its inflated size.
#
# It is not required by cybertrain/http/request.rb (CRuby loads that file
# for the framework's portable tests and script/check-http-layer, and the
# FFI DSL exists only under Spinel): `require "cybertrain"` loads it and
# installs it into Request.inflater; a program that lifts the HTTP layer out
# and wants gzip bodies requires this file and calls GzipFFI.install!.
#
# It also installs {GzipFFIDecoder} as the HTTP client's gzip support
# ({HttpClient.gzip_decoder}) through cybertrain/http/gzip_decoder.rb, a
# file the client requires too: neither this file nor the client pulls the
# other into a program. A response kept whole is inflated with {.gunzip}; a
# streamed one through the incremental inflater below, a piece of at most
# PIECE_BYTES at a time whatever the compression ratio.
#
# The FFI rules of spikes/NOTES.md (6, 15) apply: the out-parameter is a
# fresh malloc(8) scratch slot per call, never a static ffi_buffer.
require "cybertrain/http/request"
require "cybertrain/http/gzip_decoder"

module Cybertrain
  # The gzip inflater {Request#decoded_body} uses: `require "cybertrain"`
  # installs it. A program that loads only the HTTP layer requires
  # `cybertrain/http/gzip_ffi` and calls {.install!} itself.
  # @api public
  module GzipFFI
    ffi_lib "z"

    # cybertrain_gunzip_bounded(in, in_len, max_out, out_slot): inflates a
    # gzip stream (every member of a multi-member file, as RFC 1952 allows)
    # into a malloc'd buffer whose address it writes into *out_slot, and
    # returns the byte count. The buffer holds at most max_out + 1 bytes: the
    # one extra byte is how "over the limit" is detected without inflating
    # further. Negative returns: -1 the data is not valid gzip (a bad header,
    # a corrupt block, a wrong CRC, bytes after the last member that are not
    # another member, a truncated stream, or more input than zlib's uInt
    # counts), -2 the inflated size exceeds max_out, -3 out of memory, -4
    # zlib could not be initialised. Nothing is allocated for the caller on
    # a negative return.
    #
    # The incremental inflater, for a streamed body. A handle is the address
    # of a malloc'd cybertrain_inflate (a long, 0 for none), one per body:
    # cybertrain_inflate_open() makes it (0: out of memory or zlib would
    # not initialise); cybertrain_inflate_push(h, in, len) copies `len`
    # input bytes into it, after whatever input the last pulls left (-1 for
    # a bad length, -3 out of memory); cybertrain_inflate_pull(h, max)
    # inflates into the handle's own output buffer and returns how many
    # bytes it holds, at most `max` (and at most 64 KiB), 0 once the input
    # is used up, -1 for data that is not gzip (a bad header or block, a
    # wrong CRC, bytes after a member that do not start another), -3 out of
    # memory; cybertrain_inflate_piece(h, n) hands those `n` bytes to Ruby
    # (the :binstr bridge below); cybertrain_inflate_done(h) is 1 when the
    # input so far ends exactly at the end of a gzip member;
    # cybertrain_inflate_close(h) frees it all. Members follow one another
    # as in cybertrain_gunzip_bounded.
    #
    # cybertrain_bytes_at(ptr, len) is the :binstr bridge: it publishes len
    # in sp_ffi_bin_len (the TLS int the codegen declares for any module with
    # a :binstr function) and returns the pointer, so Spinel copies exactly
    # len bytes, NULs included, into a new String; the caller then frees ptr.
    ffi_source <<~C
      #include <zlib.h>
      #include <stdlib.h>
      #include <string.h>
      #include <limits.h>
      long cybertrain_gunzip_bounded(const char *in, long in_len, long max_out, void *out_slot) {
        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        if (in_len < 0 || max_out < 0 || (unsigned long)in_len > (unsigned long)UINT_MAX) return -1;
        if (inflateInit2(&zs, 15 + 16) != Z_OK) return -4;
        size_t ceiling = (size_t)max_out + 1;
        size_t cap = (size_t)in_len * 4 + 1024;
        if (cap > ceiling) cap = ceiling;
        char *out = (char *)malloc(cap);
        if (!out) { inflateEnd(&zs); return -3; }
        size_t len = 0;
        zs.next_in = (Bytef *)in;
        zs.avail_in = (uInt)in_len;
        for (;;) {
          if (len == cap) {
            if (cap >= ceiling) { free(out); inflateEnd(&zs); return -2; }
            size_t grown = cap * 2;
            if (grown > ceiling) grown = ceiling;
            char *bigger = (char *)realloc(out, grown);
            if (!bigger) { free(out); inflateEnd(&zs); return -3; }
            out = bigger;
            cap = grown;
          }
          zs.next_out = (Bytef *)(out + len);
          zs.avail_out = (uInt)(cap - len);
          int rc = inflate(&zs, Z_NO_FLUSH);
          len = cap - zs.avail_out;
          if (len > (size_t)max_out) { free(out); inflateEnd(&zs); return -2; }
          if (rc == Z_STREAM_END) {
            if (zs.avail_in == 0) break;
            if (inflateReset(&zs) != Z_OK) { free(out); inflateEnd(&zs); return -1; }
            continue;
          }
          if (rc == Z_BUF_ERROR) {
            if (zs.avail_out != 0) { free(out); inflateEnd(&zs); return -1; }
            continue;
          }
          if (rc == Z_MEM_ERROR) { free(out); inflateEnd(&zs); return -3; }
          if (rc != Z_OK) { free(out); inflateEnd(&zs); return -1; }
        }
        inflateEnd(&zs);
        *(char **)out_slot = out;
        return (long)len;
      }
      #define CYBERTRAIN_INFLATE_OUT 65536
      struct cybertrain_inflate {
        z_stream zs;
        int ended;
        char *in;
        char out[CYBERTRAIN_INFLATE_OUT];
      };
      long cybertrain_inflate_open(void) {
        struct cybertrain_inflate *st = (struct cybertrain_inflate *)calloc(1, sizeof(struct cybertrain_inflate));
        if (!st) return 0;
        if (inflateInit2(&st->zs, 15 + 16) != Z_OK) { free(st); return 0; }
        return (long)st;
      }
      long cybertrain_inflate_push(long h, const char *in, long in_len) {
        struct cybertrain_inflate *st = (struct cybertrain_inflate *)h;
        if (in_len < 0) return -1;
        size_t left = st->zs.avail_in;
        if ((unsigned long)in_len + left > (unsigned long)UINT_MAX) return -1;
        char *buf = (char *)malloc(left + (size_t)in_len + 1);
        if (!buf) return -3;
        if (left > 0) memcpy(buf, st->zs.next_in, left);
        memcpy(buf + left, in, (size_t)in_len);
        free(st->in);
        st->in = buf;
        st->zs.next_in = (Bytef *)buf;
        st->zs.avail_in = (uInt)(left + (size_t)in_len);
        return 0;
      }
      long cybertrain_inflate_pull(long h, long max_out) {
        struct cybertrain_inflate *st = (struct cybertrain_inflate *)h;
        if (max_out <= 0) return 0;
        if (max_out > CYBERTRAIN_INFLATE_OUT) max_out = CYBERTRAIN_INFLATE_OUT;
        size_t got = 0;
        while (got < (size_t)max_out) {
          if (st->ended) {
            if (st->zs.avail_in == 0) break;
            if (inflateReset(&st->zs) != Z_OK) return -1;
            st->ended = 0;
          }
          st->zs.next_out = (Bytef *)(st->out + got);
          st->zs.avail_out = (uInt)((size_t)max_out - got);
          int rc = inflate(&st->zs, Z_NO_FLUSH);
          got = (size_t)max_out - st->zs.avail_out;
          if (rc == Z_STREAM_END) { st->ended = 1; continue; }
          if (rc == Z_BUF_ERROR) break;
          if (rc == Z_MEM_ERROR) return -3;
          if (rc != Z_OK) return -1;
        }
        return (long)got;
      }
      const char *cybertrain_inflate_piece(long h, long len) {
        struct cybertrain_inflate *st = (struct cybertrain_inflate *)h;
        sp_ffi_bin_len = (int)len;
        return st->out;
      }
      long cybertrain_inflate_done(long h) {
        struct cybertrain_inflate *st = (struct cybertrain_inflate *)h;
        return (st->ended && st->zs.avail_in == 0) ? 1 : 0;
      }
      void cybertrain_inflate_close(long h) {
        struct cybertrain_inflate *st = (struct cybertrain_inflate *)h;
        if (!st) return;
        inflateEnd(&st->zs);
        free(st->in);
        free(st);
      }
      const char *cybertrain_bytes_at(void *ptr, long len) {
        sp_ffi_bin_len = (int)len;
        return (const char *)ptr;
      }
    C
    ffi_func :cybertrain_gunzip_bounded, [:str, :long, :long, :ptr], :long
    ffi_func :cybertrain_bytes_at, [:ptr, :long], :binstr
    ffi_func :cybertrain_inflate_open, [], :long
    ffi_func :cybertrain_inflate_push, [:long, :str, :long], :long
    ffi_func :cybertrain_inflate_pull, [:long, :long], :long
    ffi_func :cybertrain_inflate_piece, [:long, :long], :binstr
    ffi_func :cybertrain_inflate_done, [:long], :long
    ffi_func :cybertrain_inflate_close, [:long], :void
    ffi_func :malloc, [:size_t], :ptr
    ffi_func :free, [:ptr], :void
    ffi_read_ptr :read_ptr, 0

    # sp_ffi_bin_len is a C int: the largest body this bridge can hand back.
    MAX_LIMIT = 2_147_483_647

    # The most a streamed body's inflater hands back at a time (the size of
    # its C output buffer).
    PIECE_BYTES = 65_536

    # Inflates `data` (a gzip body) under `limit` bytes of output. Raises
    # BodyUndecodable for anything that is not one or more valid gzip members
    # and BodyTooLarge when the inflated size would pass the limit (at most
    # limit + 1 bytes are ever inflated). The result is tagged UTF-8 like a
    # body sent plain (a socket buffer is a UTF-8 String under Spinel), not
    # binary as the FFI bridge hands it back, so the two compare and
    # concatenate alike; it is validated like any request text by whoever
    # parses it.
    def self.gunzip(data, limit)
      raise ArgumentError, "limit must be between 0 and #{MAX_LIMIT}" if limit < 0 || limit > MAX_LIMIT

      # Explicit receivers: an FFI function is a module function, called as
      # GzipFFI.name even from inside the module (a bare call does not resolve).
      slot = GzipFFI.malloc(8)
      rc = GzipFFI.cybertrain_gunzip_bounded(data, data.bytesize, limit, slot)
      if rc < 0
        GzipFFI.free(slot)
        raise BodyTooLarge, "request body inflates to more than #{limit} bytes" if rc == -2
        raise BodyUndecodable, "request body is not valid gzip data" if rc == -1

        raise BodyUndecodable, "request body could not be inflated (zlib error #{rc})"
      end
      out = GzipFFI.read_ptr(slot)
      GzipFFI.free(slot)
      text = GzipFFI.cybertrain_bytes_at(out, rc)
      GzipFFI.free(out)
      text.force_encoding("UTF-8")
    end

    # The lambda Request#decoded_body calls (a method-returned lambda, as
    # NOTES rule 42 asks).
    def self.inflater
      ->(data, limit) { GzipFFI.gunzip(data, limit) }
    end

    # Makes {Request#decoded_body} inflate through this module.
    # @return [nil]
    # @api public
    def self.install!
      Request.inflater = inflater
      nil
    end
  end

  # The HTTP client's gzip support, installed as {HttpClient.gzip_decoder}
  # by requiring this file. Each response body gets its own (#gzip_open);
  # a streamed one holds a z_stream, made at its first push and freed by
  # #gzip_close. Internal.
  class GzipFFIDecoder < GzipDecoder
    def initialize
      super()
      @handle = 0
    end

    def gzip_ready?
      true
    end

    def gzip_open
      GzipFFIDecoder.new
    end

    # GzipFFI.gunzip, its two errors turned into a status. A limit past
    # what the bridge hands back is clamped to it.
    def gzip_whole(data, limit)
      ceiling = limit > GzipFFI::MAX_LIMIT ? GzipFFI::MAX_LIMIT : limit
      text = GzipFFI.gunzip(data, ceiling)
      @gzip_status = GzipDecoder::GZIP_OK
      text
    rescue Cybertrain::BodyTooLarge
      @gzip_status = GzipDecoder::GZIP_TOO_LARGE
      ""
    rescue Cybertrain::BodyUndecodable
      @gzip_status = GzipDecoder::GZIP_UNDECODABLE
      ""
    end

    def gzip_push(data)
      return nil if @gzip_status != GzipDecoder::GZIP_OK

      if @handle == 0
        @handle = GzipFFI.cybertrain_inflate_open
        if @handle == 0
          @gzip_status = GzipDecoder::GZIP_UNDECODABLE
          return nil
        end
      end
      rc = GzipFFI.cybertrain_inflate_push(@handle, data, data.bytesize)
      @gzip_status = GzipDecoder::GZIP_UNDECODABLE if rc < 0
      nil
    end

    # Tagged UTF-8 like GzipFFI.gunzip's result and a chunk read plain.
    def gzip_pull
      return "" if @handle == 0 || @gzip_status != GzipDecoder::GZIP_OK

      n = GzipFFI.cybertrain_inflate_pull(@handle, GzipFFI::PIECE_BYTES)
      if n < 0
        @gzip_status = GzipDecoder::GZIP_UNDECODABLE
        return ""
      end
      return "" if n == 0

      piece = GzipFFI.cybertrain_inflate_piece(@handle, n)
      piece.force_encoding("UTF-8")
    end

    def gzip_done?
      return false if @handle == 0 || @gzip_status != GzipDecoder::GZIP_OK

      GzipFFI.cybertrain_inflate_done(@handle) == 1
    end

    def gzip_close
      GzipFFI.cybertrain_inflate_close(@handle) if @handle != 0
      @handle = 0
      nil
    end
  end

  GzipDecoder.installed = GzipFFIDecoder.new
end
