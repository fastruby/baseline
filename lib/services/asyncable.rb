require 'active_support/concern'

begin
  require 'sidekiq'
  require 'sidekiq/api'
rescue LoadError
  raise Services::BackgroundProcessorNotFound
end

module Services
  module Asyncable
    extend ActiveSupport::Concern

    ASYNC_METHOD_SUFFIXES = %i(async in at).freeze

    included do
      include Sidekiq::Worker
    end

    module ClassMethods
      # Bulk enqueue items
      # args can either be a one-dimensional or two-dimensional array,
      # each item in args should be the arguments for one job.
      def bulk_call_async(args)
        # Convert args to two-dimensional array if it isn't one already.
        args = args.map { |arg| [arg] } if args.none? { |arg| arg.is_a?(Array) }
        Sidekiq::Client.push_bulk 'class' => self, 'args' => args
      end

      ASYNC_METHOD_SUFFIXES.each do |async_method_suffix|
        define_method "call_#{async_method_suffix}" do |*args|
          self.public_send "perform_#{async_method_suffix}", *args
        end
      end
    end

    def perform(*args)
      self.call *args
    end
  end
end
