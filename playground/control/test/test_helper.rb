# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "play"
require_relative "fakes"
