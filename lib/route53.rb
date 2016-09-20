class Route53
	attr_reader :client

	def initialize(cloudmgr)
		@mgr = cloudmgr
		@client = Aws::Route53::Client.new( region: @mgr["Region"] )
	end

	def normalize_name(name)
		return name if name.end_with?(@mgr["ConfigDom"] + ".")
		suffix = @mgr["DNSDomain"]
		suffix = "." + suffix unless suffix.start_with?(".")
		name = name + suffix unless name.end_with?(suffix)
		name = name + "." unless name.end_with?(".")
		return name
	end

	def normalize_name_parameters()
		["name", "cname"].each() do |name|
			normalized = @mgr.getparam(name)
			next unless normalized
			next if normalized.end_with?(@mgr["ConfigDom"] + ".")
			suffix = @mgr["DNSDomain"]
			suffix = "." + suffix unless suffix.start_with?(".")
			normalized = normalized + suffix unless normalized.end_with?(suffix)
			normalized = normalized + "." unless normalized.end_with?(".")
			@mgr.setparam(name, normalized)
		end
		name = @mgr.getparam("name")
		if name and not @mgr.getparam("iname")
			si = name.index("." + @mgr["DNSBase"])
			iname = name[0..(si-1)]
			@mgr.setparam("iname", iname)
		end
		#puts "name: #{@mgr.getparam("name")}, cname: #{@mgr.getparam("cname")} iname: #{@mgr.getparam("iname")}"
	end

	def lookup(name, zone)
		name = normalize_name(name)
		lookup = {
			hosted_zone_id: zone,
			start_record_name: name,
			max_items: 1,
		}
		#puts "Looking up: #{lookup}"
		records = @client.list_resource_record_sets(lookup)
		values = []
		return values unless records.resource_record_sets[0].name == name
		records.resource_record_sets[0].resource_records.each do |record|
			values << record.value
		end
		return values
	end

	def change_records(template)
		normalize_name_parameters()
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
