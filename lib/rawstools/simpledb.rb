module RAWSTools
	class SimpleDB
		attr_reader :client

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::SimpleDB::Client.new( region: @mgr["Region"] )
		end

		def getdomain()
			dom = @mgr.getparam("sdbdomain")
			return dom if dom
			dom = @mgr["ConfigDB"]
			raise "Couldn't determine SimpleDB domain; parameter 'sdbdomain' unset and no value for 'ConfigDB' in cloud config file" unless dom
			return dom
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
			#puts "Looking for attribute #{key} in #{item} from domain #{dom}"
			values = @client.get_attributes({
				domain_name: dom,
				item_name: item,
				attribute_names: [ key ],
				consistent_read: true,
			}).attributes.map { |attr| attr.value() }
		end
	end
end
