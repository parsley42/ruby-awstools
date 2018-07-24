module RAWSTools
  class SimpleDB
    attr_reader :client

    def initialize(cloudmgr)
      @mgr = cloudmgr
      @client = Aws::SimpleDB::Client.new( @mgr.client_opts )
    end

    def getdomain()
      dom = @mgr.getparam("sdbdomain")
      return @mgr[dom] if dom
      dom = @mgr["DefaultSDB"]
      return @mgr[dom] if dom
      raise "Couldn't determine SimpleDB domain; parameter 'sdbdomain' unset and couldn't resolve a db from DefaultSDB in cloud config file"
    end

    def store(item, key, value, replace=true)
      dom = getdomain()
      @client.put_attributes({
        domain_name: dom,
        item_name: item,
        attributes: [
          name: key,
          value: value,
          replace: replace,
        ]
      })
    end

    def retrieve(item, key)
      dom = getdomain()
#      puts "Looking for attribute #{key} in #{item} from domain #{dom}"
      @client.get_attributes({
        domain_name: dom,
        item_name: item,
        attribute_names: [ key ],
        consistent_read: true,
      }).attributes.map { |attr| attr.value() }
    end
  end
end
