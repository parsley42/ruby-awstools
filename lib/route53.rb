	class Route53
		attr_reader :client

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::Route53::Client.new( region: @mgr["Region"] )
		end

		def lookup(name)
			records = @client.list_resource_record_sets({
				hosted_zone_id: @mgr.getparam("zone_id"),
				start_record_name: name,
				max_items: 1,
			})
			values = []
			records.resource_record_sets[0].resource_records.each do |record|
				values << record.value
			end
			values
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
			resp.change_info.id
		end

		def sync_wait(change_id)
			@client.wait_until(:resource_record_sets_changed, id: change_id )
		end
	end

