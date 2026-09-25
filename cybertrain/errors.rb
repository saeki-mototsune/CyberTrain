module Cybertrain
  # Validation messages of one record, keyed by attribute (ActiveModel::Errors).
  class Errors
    def initialize
      # Seeded with its element types, then emptied (spikes/NOTES.md rule 9).
      @messages = { base: Array.new(0) { "" } }
      @messages.delete(:base)
    end

    def add(attr, message)
      list = @messages[attr]
      if list.nil?
        @messages[attr] = [message]
      else
        list << message
      end
      nil
    end

    def [](attr)
      list = @messages[attr]
      list.nil? ? Array.new(0) { "" } : list
    end

    def any?
      !@messages.empty?
    end

    def empty?
      @messages.empty?
    end

    def count
      n = 0
      @messages.each_value { |list| n += list.size }
      n
    end

    def clear
      @messages.clear
      nil
    end

    def key?(attr)
      @messages.key?(attr)
    end

    def keys
      @messages.keys
    end

    # "Title can't be blank": the attribute humanized, then the message.
    def full_messages
      out = Array.new(0) { "" }
      @messages.each do |attr, list|
        label = attr.to_s.tr("_", " ").capitalize
        list.each { |message| out << "#{label} #{message}" }
      end
      out
    end

    def each
      @messages.each do |attr, list|
        list.each { |message| yield attr, message }
      end
    end
  end
end
