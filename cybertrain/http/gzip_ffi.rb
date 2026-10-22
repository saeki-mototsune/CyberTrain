# Cybertrain::GzipFFI -- the gzip inflater behind Request#decoded_body, bound
# to the system zlib (-lz, zlib.h) through Spinel FFI.
#
# Spinel's own `zlib` package inflates in one shot into a buffer that grows
# without bound, so it cannot refuse a body that is small on the wire and
# huge once inflated (a "zip bomb": DEFLATE expands up to about 1032 times,
# and a lying gzip trailer hides the size). This module streams through
# zlib's inflate() with a ceiling on the output: the request is refused the
# moment the inflated bytes pass the limit, with at most limit + 1 bytes ever
# allocated, in C, with no Ruby String in between.
#
# It is not required by cybertrain/http/request.rb (CRuby loads that file
# for the framework's portable tests and script/check-http-layer, and the
# FFI DSL exists only under Spinel): `require "cybertrain"` loads it and
# installs it into Request.inflater; a program that lifts the HTTP layer out
# and wants gzip bodies requires this file and calls GzipFFI.install!.
#
# The FFI rules of spikes/NOTES.md (6, 15) apply: the out-parameter is a
# fresh malloc(8) scratch slot per call, never a static ffi_buffer.
require "cybertrain/http/request"

module Cybertrain
  module GzipFFI
    ffi_lib "z"

    # cybertrain_gunzip_bounded(in, in_len, max_out, out_slot): inflates a
    # gzip stream (every member of a multi-member file, as RFC 1952 allows)
    # into a malloc'd buffer whose address it writes into *out_slot, and
    # returns the byte count. The buffer holds at most max_out + 1 bytes: the
    # one extra byte is how "over the limit" is detected without inflating
    # further. Negative returns: -1 the data is not valid gzip (a bad header,
    # a corrupt block, a wrong CRC, bytes after the last member that are not
    # another member, or a truncated stream), -2 the inflated size exceeds
    # max_out, -3 out of memory, -4 zlib could not be initialised. Nothing is
    # allocated for the caller on a negative return.
    #
    # cybertrain_bytes_at(ptr, len) is the :binstr bridge: it publishes len
    # in sp_ffi_bin_len (the TLS int the codegen declares for any module with
    # a :binstr function) and returns the pointer, so Spinel copies exactly
    # len bytes, NULs included, into a new String; the caller then frees ptr.
    ffi_source <<~C
      #include <zlib.h>
      #include <stdlib.h>
      #include <string.h>
      long cybertrain_gunzip_bounded(const char *in, long in_len, long max_out, void *out_slot) {
        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        if (in_len < 0 || max_out < 0) return -1;
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
          if (rc != Z_OK) { free(out); inflateEnd(&zs); return -1; }
        }
        inflateEnd(&zs);
        *(char **)out_slot = out;
        return (long)len;
      }
      const char *cybertrain_bytes_at(void *ptr, long len) {
        sp_ffi_bin_len = (int)len;
        return (const char *)ptr;
      }
    C
    ffi_func :cybertrain_gunzip_bounded, [:str, :long, :long, :ptr], :long
    ffi_func :cybertrain_bytes_at, [:ptr, :long], :binstr
    ffi_func :malloc, [:size_t], :ptr
    ffi_func :free, [:ptr], :void
    ffi_read_ptr :read_ptr, 0

    # sp_ffi_bin_len is a C int: the largest body this bridge can hand back.
    MAX_LIMIT = 2_147_483_647

    # Inflates `data` (a gzip body) under `limit` bytes of output. Raises
    # BodyUndecodable for anything that is not one or more valid gzip members
    # and BodyTooLarge when the inflated size would pass the limit (at most
    # limit + 1 bytes are ever inflated).
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
      text
    end

    # The lambda Request#decoded_body calls (a method-returned lambda, as
    # NOTES rule 42 asks).
    def self.inflater
      ->(data, limit) { GzipFFI.gunzip(data, limit) }
    end

    def self.install!
      Request.inflater = inflater
      nil
    end
  end
end
