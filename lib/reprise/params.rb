# frozen_string_literal: true

module Reprise
  # Request params: a Hash with String keys that also accepts Symbols, as Sinatra's IndifferentHash does. Nested
  # Hashes, including those inside Arrays, are converted too, so `params[:user][:name]` works.
  class Params < Hash
    def self.[](*args) = new.merge!(Hash[*args])

    def default(*args)
      args.map! { convert_key(it) }
      super
    end

    def default=(value)
      super(convert_value(value))
    end

    def assoc(key) = super(convert_key(key))
    def rassoc(value) = super(convert_value(value))
    def [](key) = super(convert_key(key))
    def key(value) = super(convert_value(value))
    def key?(key) = super(convert_key(key))
    def value?(value) = super(convert_value(value))
    def delete(key) = super(convert_key(key))
    def dig(key, *keys) = super(convert_key(key), *keys)

    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?
    alias_method :has_value?, :value?

    def fetch(key, *args)
      args.map! { convert_value(it) }
      super(convert_key(key), *args)
    end

    def []=(key, value)
      super(convert_key(key), convert_value(value))
    end
    alias_method :store, :[]=

    def fetch_values(*keys) = super(*keys.map { convert_key(it) })
    def values_at(*keys) = super(*keys.map { convert_key(it) })
    def slice(*keys) = self.class[super(*keys.map { convert_key(it) })]
    def except(*keys) = self.class[super(*keys.map { convert_key(it) })]

    def merge!(*others)
      others.each do |other|
        if other.is_a?(self.class)
          super(other)
        else
          other.each_pair do |key, value|
            key = convert_key(key)
            value = yield(key, self[key], value) if block_given? && key?(key)
            self[key] = convert_value(value)
          end
        end
      end
      self
    end
    alias_method :update, :merge!

    def merge(*others, &block) = dup.merge!(*others, &block)

    def replace(other) = super(other.is_a?(self.class) ? other : self.class[other])

    def transform_values(&block) = dup.transform_values!(&block)

    def transform_values!
      super
      super { convert_value(it) }
    end

    def transform_keys(&block) = dup.transform_keys!(&block)

    def transform_keys!
      super
      super { convert_key(it) }
    end

    def select(*args, &block)
      return to_enum(:select) unless block

      dup.tap { it.select!(*args, &block) }
    end

    def reject(*args, &block)
      return to_enum(:reject) unless block

      dup.tap { it.reject!(*args, &block) }
    end

    def compact = dup.tap(&:compact!)

    private

    def convert_key(key) = key.is_a?(Symbol) ? key.name : key

    def convert_value(value)
      case value
      when self.class then value
      when Hash then self.class[value]
      when Array then value.map { convert_value(it) }
      else value
      end
    end
  end
end
