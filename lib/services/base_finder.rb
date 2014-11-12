module Services
  class BaseFinder < Services::Base
    def call(ids = [], conditions = {})
      ids, conditions = Array(ids), conditions.symbolize_keys
      special_conditions = conditions.extract!(:order, :limit, :page, :per_page)
      scope = service_class
        .select("DISTINCT #{service_class.table_name}.id")
        .order("#{service_class.table_name}.id")
      scope = scope.where(id: ids) unless ids.empty?

      scope = process(scope, conditions)

      scope = service_class.where(id: scope)
      special_conditions.each do |k, v|
        case k
        when :order
          order = if v == 'random'
            'RANDOM()'
          else
            "#{service_class.table_name}.#{v}"
          end
          scope = scope.order(order)
        when :limit
          scope = scope.limit(v)
        when :page
          scope = scope.page(v)
        when :per_page
          scope = scope.per(v)
        else
          raise ArgumentError, "Unexpected special condition: #{k}"
        end
      end
      scope
    end
  end
end
