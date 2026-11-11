module Cybertrain
  # What {Controller#respond_to} yields: one method per format, each a
  # declaration that this action answers it.
  #
  #     respond_to do |format|
  #       format.html
  #       format.json { render json: @article.as_json }
  #       format.turbo_stream
  #     end
  #
  # The request's format is known before the action runs, so the first
  # declaration that matches it runs its block at once, as it is declared;
  # the declarations after it do nothing. No block is ever stored (spikes/
  # NOTES.md rule 88). A declaration without a block leaves the render to
  # {Controller#respond_to}: the action's template for that format. When
  # nothing matched, respond_to answers `406 Not Acceptable`.
  #
  # `any` matches whatever format the request has, if no declaration before
  # it matched; not a format whose extension is unregistered (`:unknown`,
  # see {Request#format}), which only 406 answers, as in Rails.
  # @api public
  class FormatCollector
    # @param format [Symbol] the request's format ({Request#format})
    def initialize(format)
      @format = format
      @matched_format = :none
      @matched_without_block = false
    end

    # @yield runs when the request asks for HTML
    # @return [nil]
    # @api public
    def html(&block)
      arm(:html, block)
    end

    # @yield runs when the request asks for JSON
    # @return [nil]
    # @api public
    def json(&block)
      arm(:json, block)
    end

    # @yield runs when the request asks for a Turbo Stream
    # @return [nil]
    # @api public
    def turbo_stream(&block)
      arm(:turbo_stream, block)
    end

    # @yield runs when the request asks for CSV
    # @return [nil]
    # @api public
    def csv(&block)
      arm(:csv, block)
    end

    # @yield runs when the request asks for XML
    # @return [nil]
    # @api public
    def xml(&block)
      arm(:xml, block)
    end

    # @yield runs when the request asks for plain text (`.txt`, `.text`)
    # @return [nil]
    # @api public
    def text(&block)
      arm(:text, block)
    end

    # @yield runs for any registered format no declaration before it matched
    # @return [nil]
    # @api public
    def any(&block)
      return nil if @format == :unknown

      arm(@format, block)
    end

    # The format whose declaration matched, `:none` until one did.
    # @return [Symbol]
    # @api public
    def matched_format
      @matched_format
    end

    # Whether the matching declaration came without a block (the action's
    # template for that format is then rendered).
    # @return [Boolean]
    # @api public
    def matched_without_block?
      @matched_without_block
    end

    private

    def arm(format, block)
      return nil unless @matched_format == :none
      return nil unless format == @format

      @matched_format = format
      if block.nil?
        @matched_without_block = true
      else
        block.call
      end
      nil
    end
  end
end
