class Route53
	attr_reader :client

	def initialize(cloudmgr)
		@mgr = cloudmgr
		@client = Aws::Route53::Client.new( region: @mgr["Region"] )
	end

	def lookup(name, zone)
		name = name + "." unless name.end_with?(".")
		records = @client.list_resource_record_sets({
			hosted_zone_id: zone,
			start_record_name: name,
			max_items: 1,
		})
		values = []
		return values unless records.resource_record_sets[0].name == name
		records.resource_record_sets[0].resource_records.each do |record|
			values << record.value
		end
		return values
	end

	def change_records(template)
		templatefile = nil
		if File::exist?("route53/#{template}.json")
			templatefile = "route53/#{template}.json"
		else
			templatefile = "#{@mgr.installdir}/templates/route53/#{template}.yaml"
		end
		raw = File::read(templatefile)
		raw = @mgr.expand_strings(raw)
		set = YAML::load(raw)

		@mgr.resolve_vars( { "child" => set }, "child" )
		@mgr.symbol_keys(set)

		resp = @client.change_resource_record_sets(set)
		return resp
	end

	def wait_sync(change)
		@client.wait_until(:resource_record_sets_changed, id: change.change_info.id )
	end
end
