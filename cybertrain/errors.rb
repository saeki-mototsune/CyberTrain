module Cybertrain
  # Validation messages of one record, keyed by attribute (ActiveModel::Errors).
  # Every model has one, {Model#errors}, cleared and refilled by
  # {Model#valid?}.
  #
  # Keys are the Symbols the validations use (`:title`); a String key is a
  # different key. In a template: `article.errors.any?`,
  # `article.errors.full_messages`, `article.errors[:title]`.
  # @api public
  class Errors
    def initialize
      # Seeded with its element types, then emptied (spikes/NOTES.md rule 9).
      @messages = { base: Array.new(0) { "" } }
      @messages.delete(:base)
    end

    # Adds a message for an attribute; `:base` for the record as a whole.
    # @example
    #   before_validation { |r| r.errors.add(:base, "Pick a date") if r.starts_on.nil? }
    # @param attr [Symbol]
    # @param message [String] e.g. `"is taken"`, shown after the humanized
    #   attribute by {#full_messages}
    # @return [nil]
    # @api public
    def add(attr, message)
      list = @messages[attr]
      if list.nil?
        @messages[attr] = [message]
      else
        list << message
      end
      nil
    end

    # @param attr [Symbol]
    # @return [Array<String>] the messages for that attribute, `[]` if none
    # @api public
    def [](attr)
      list = @messages[attr]
      list.nil? ? Array.new(0) { "" } : list
    end

    # @return [Boolean] true when there is at least one message
    # @api public
    def any?
      !@messages.empty?
    end

    # @return [Boolean] true when there are no messages
    # @api public
    def empty?
      @messages.empty?
    end

    # @return [Integer] the number of messages, over every attribute
    # @api public
    def count
      n = 0
      @messages.each_value { |list| n += list.size }
      n
    end

    # Removes every message.
    # @return [nil]
    # @api public
    def clear
      @messages.clear
      nil
    end

    # @param attr [Symbol]
    # @return [Boolean] true when the attribute has a message
    # @api public
    def key?(attr)
      @messages.key?(attr)
    end

    # @return [Array<Symbol>] the attributes that have messages, in the
    #   order they were first added
    # @api public
    def keys
      @messages.keys
    end

    # "Title can't be blank": the attribute humanized, then the message.
    # Humanizing replaces `_` with a space and capitalizes, so `:article_id`
    # gives `"Article id ..."` and `:base` gives `"Base ..."`.
    # @example
    #   @article.errors.full_messages.join(", ")
    # @return [Array<String>]
    # @api public
    def full_messages
      out = Array.new(0) { "" }
      @messages.each do |attr, list|
        label = attr.to_s.tr("_", " ").capitalize
        list.each { |message| out << "#{label} #{message}" }
      end
      out
    end

    # Yields every message with its attribute.
    # @yieldparam attr [Symbol]
    # @yieldparam message [String]
    # @api public
    def each
      @messages.each do |attr, list|
        list.each { |message| yield attr, message }
      end
    end
  end
end
