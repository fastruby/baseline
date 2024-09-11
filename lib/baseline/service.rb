require "active_record"
require "securerandom"
require "action_dispatch"
require "digest"

require "baseline/service/call_logger"
require "baseline/service/exception_wrapper"
require "baseline/service/uniqueness_checker"

module Baseline
  class Service
    delegate :link_to, :tag, :link_to_modal, :pluralize, to: :"ApplicationController.helpers"
    delegate :t, :l, to: :"I18n"

    class << self
      def inherited(subclass)
        subclass.const_set :Error, Class.new(StandardError)

        if defined?(Rails)
          subclass.public_send :include, Rails.application.routes.url_helpers
        end

        begin
          subclass.public_send :include, Asyncable
        rescue Baseline::NoBackgroundProcessorFound
        end
        subclass.public_send :prepend, CallLogger, ExceptionWrapper, UniquenessChecker
      end

      delegate :call, to: :new

      def enqueued?(*args)
        enqueued_jobs(*args).any?
      end

      def processing?(*args)
        processing_jobs(*args).any?
      end

      def enqueued_or_processing?(*args)
        enqueued?(*args) || processing?(*args)
      end

      def scheduled_at(*args)
        scheduled_jobs(*args).first
                             &.at
                             &.in_time_zone
      end
    end

    {
      enqueued:   -> {
                       defined?(Sidekiq::Testing) && Sidekiq::Testing.fake? ?
                       Sidekiq::Job.jobs
                                   .map { Sidekiq::JobRecord.new _1 unless _1.key?("at") }
                                   .compact :
                       Sidekiq::Queue.all
                                     .flat_map(&:to_a)
                     },
      scheduled:  -> {
                       defined?(Sidekiq::Testing) && Sidekiq::Testing.fake? ?
                       Sidekiq::Job.jobs
                                   .map { Sidekiq::JobRecord.new _1 if _1.key?("at") }
                                   .compact :
                       Sidekiq::ScheduledSet.new
                     },
      processing: -> {
                       Sidekiq::WorkSet.new.map do |_, _, work|
                         payload = JSON.parse(work["payload"], symbolize_names: true)
                         OpenStruct.new(
                           {
                             klass: :class,
                             args:  :args
                           }.transform_values { payload.fetch(_1) }
                         )
                       end
                     }
    }.each do |type, job_fetcher|
      define_singleton_method "#{type}_jobs" do |*args|
        args = args.map do |arg|
          case arg = arg
          when Symbol then arg.to_s
          when Hash   then arg.stringify_keys
          when Array  then arg.map { _1.is_a?(Symbol) ? _1.to_s : _1 }
          else             arg
          end
        end

        job_fetcher.call.select do |job_record|
          job_record.klass == self.to_s && (args.none? || job_record.args.take(args.size) == args)
        end
      end
    end

    def initialize
      @id = SecureRandom.hex(6)
    end

    def call(*args, **kwargs)
      raise NotImplementedError
    end

    private

      def log(level, message, **kwargs)
        message = [
          message,
          kwargs.reverse_merge(service: self.class.to_s, id: @id)
                .map { [_1, _2].join(": ") }
                .join(", ")
                .then { "(#{_1})" }
        ].join(" ")

        Rails.logger.public_send level, message
      end

      def object_class
        self.class.to_s[/\A(?:Baseline::)?([^:]+)/, 1].singularize.constantize
      rescue
        raise "Could not determine service class from #{self.class}."
      end

      def track_last_run(cache_key_part = nil)
        now         = Time.current
        cache_key   = [self.class.to_s.underscore, cache_key_part, "last_run"].compact.join("_")
        last_run_at = Kredis.redis
                            .get(cache_key)
                            &.then { Time.zone.parse _1 }

        yield *[last_run_at].compact

        Kredis.redis.set cache_key, now.iso8601
      end

      def call_all_private_methods_without_args(raise_errors: true)
        private_methods(false).map { method _1 }
                              .select { _1.arity == 0 }
                              .sort_by { _1.source_location.last }
                              .each do |method|
          method.call
        rescue => error
          if raise_errors
            raise error
          else
            ReportError.call error
          end
        end
      end
  end
end
