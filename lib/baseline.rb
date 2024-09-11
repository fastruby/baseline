module Baseline
  NoBackgroundProcessorFound = Class.new(StandardError)
  RedisNotFound              = Class.new(StandardError)

  class << self
    def redis=(redis)
      @redis = redis
    end

    def redis
      @redis ||= configuration.redis || (defined?(Kredis) && Kredis.redis) \
        or raise RedisNotFound, "Redis not configured."
    end

    # def replace_records_with_global_ids(arg)
    #   method = method(__method__)

    #   case arg
    #   when Array then arg.map(&method)
    #   when Hash  then arg.transform_keys(&method)
    #                      .transform_values(&method)
    #   else arg.respond_to?(:to_global_id) ? "_#{arg.to_global_id.to_s}" : arg
    #   end
    # end

    # def replace_global_ids_with_records(arg)
    #   method = method(__method__)

    #   case arg
    #   when Array  then arg.map(&method)
    #   when Hash   then arg.transform_keys(&method)
    #                       .transform_values(&method)
    #   when String then (arg.starts_with?("_") && GlobalID::Locator.locate(arg[1..-1])) || arg
    #   else arg
    #   end
    # end

    def has_many_reflection_classes
      [
        ActiveRecord::Reflection::HasManyReflection,
        ActiveRecord::Reflection::HasAndBelongsToManyReflection,
        ActiveRecord::Reflection::ThroughReflection
      ]
    end

    def fetch_asset_host_manifests
      return unless asset_host = Rails.application.config.asset_host
      return if ENV["SKIP_FETCH_ASSET_HOST_MANIFESTS"]

      require "http"

      path     = File.join("assets", ".manifest.json")
      content  = HTTP.get("#{asset_host}/#{path}").then { _1.body.to_s if _1.status.success? }
      pathname = Rails.root.join("public", path)

      FileUtils.mkdir_p pathname.dirname
      File.write pathname, content
    end
  end
end

require "baseline/asyncable"
require "baseline/configuration"
require "baseline/controller_extensions"
require "baseline/helper"
require "baseline/model_extensions"
require "baseline/redis_url"

if defined?(Rails)
  require "baseline/railtie"
end
