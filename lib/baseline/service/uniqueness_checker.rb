module Baseline
  class Service
    module UniquenessChecker
      KEY_PREFIX = %w(
        baseline
        uniqueness
      ).join(":")
       .freeze

      ON_ERROR = %i(
        fail
        ignore
        reschedule
        return
      ).freeze

      MAX_RETRIES = 10.freeze
      THIRTY_DAYS = (60 * 60 * 24 * 30).freeze

      def self.prepended(mod)
        mod.const_set :NotUniqueError, Class.new(mod::Error)
      end

      def check_uniqueness(*args, on_error: :fail)
        unless ON_ERROR.include?(on_error.to_sym)
          raise "on_error must be one of #{ON_ERROR.join(", ")}, but was #{on_error}"
        end

        @_on_error = on_error

        if @_service_args.nil?
          raise "Service args not found."
        end

        @_uniqueness_args = args.empty? ?
                            @_service_args :
                            args
        new_uniqueness_key = uniqueness_key(@_uniqueness_args)
        if @_uniqueness_keys && @_uniqueness_keys.include?(new_uniqueness_key)
          raise "A uniqueness key with args #{@_uniqueness_args.inspect} already exists."
        end

        if @_similar_service_id = Baseline.redis.get(new_uniqueness_key)
          if on_error.to_sym == :ignore
            return false
          else
            @_retries_exhausted = on_error.to_sym == :reschedule && error_count >= MAX_RETRIES
            raise_not_unique_error
          end
        else
          @_uniqueness_keys ||= []
          @_uniqueness_keys << new_uniqueness_key
          Baseline.redis.setex new_uniqueness_key, THIRTY_DAYS, @id
          true
        end
      end

      def call(*args, **kwargs)
        @_service_args = args
        super
      rescue self.class::NotUniqueError => e
        case @_on_error.to_sym
        when :fail
          raise e
        when :reschedule
          if @_retries_exhausted
            raise e
          else
            increase_error_count
            reschedule
          end
        when :return
          return e
        else
          raise "Unexpected on_error: #{@_on_error}"
        end
      ensure
        unless Array(@_uniqueness_keys).empty?
          Baseline.redis.del @_uniqueness_keys
        end
        Baseline.redis.del error_count_key
      end

      private

      def raise_not_unique_error
        message = [
          "Service #{self.class} #{@id} with uniqueness args #{@_uniqueness_args} is not unique, a similar service is already running: #{@_similar_service_id}.",
          ("The service has been retried #{MAX_RETRIES} times." if @_retries_exhausted)
        ].compact
         .join(" ")

        raise self.class::NotUniqueError.new(message)
      end

      def convert_for_rescheduling(arg)
        case arg
        when Array
          arg.map do |array_arg|
            convert_for_rescheduling array_arg
          end
        when Integer, String, TrueClass, FalseClass, NilClass
          arg
        when object_class
          arg.id
        else
          raise "Don't know how to convert arg #{arg.inspect} for rescheduling."
        end
      end

      def reschedule
        # Convert service args for rescheduling first
        reschedule_args = @_service_args.map do |arg|
          convert_for_rescheduling arg
        end
        log :info, "Rescheduling", seconds: retry_delay
        self.class.call_in retry_delay, *reschedule_args
      end

      def error_count
        (Baseline.redis.get(error_count_key) || 0).to_i
      end

      def increase_error_count
        Baseline.redis.setex error_count_key, retry_delay + THIRTY_DAYS, error_count + 1
      end

      def uniqueness_key(args)
        [
          KEY_PREFIX,
          self.class.to_s.gsub(":", "_")
        ].tap do |key|
          key << Digest::MD5.hexdigest(args.to_s) unless args.empty?
        end.join(":")
      end

      def error_count_key
        [
          KEY_PREFIX,
          "errors",
          self.class.to_s.gsub(":", "_")
        ].tap do |key|
          key << Digest::MD5.hexdigest(@_service_args.to_s) unless @_service_args.empty?
        end.join(":")
      end

      def retry_delay
        error_count ** 3 + 5
      end
    end
  end
end
