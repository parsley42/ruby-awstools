class Ec2
	attr_reader :client, :resource

	def initialize(cloudmgr)
		@mgr = cloudmgr
		@client = Aws::EC2::Client.new( region: @mgr["Region"] )
		@resource = Aws::EC2::Resource.new(client: @client)
	end

	def resolve(instance)
		return instance if instance.start_with?("i-")
		f = [ { name: "tag:Name", values: [instance] } ]
		i = @resource.instances(filters: f).first()
		raise "No instance found with Name: #{instance}" unless i
		return i.id()
	end

	def create_from_template(template)
		@mgr.route53.normalize_name_parameters()
		templatefile = nil
		if template.end_with?(".yaml")
			templatefile = template
		else
			templatefile = "ec2/#{template}.yaml"
		end
		raw = File::read(templatefile)
		raw = @mgr.expand_strings(raw)
		ispec = YAML::load(raw)

		@mgr.resolve_vars( { "child" => ispec }, "child" )
		@mgr.symbol_keys(ispec)
		if ispec[:user_data]
			ispec[:user_data] = Base64::encode64(ispec[:user_data])
		end
		#puts "Creating: #{ispec}"

		instances = @resource.create_instances(ispec)
		return instances
	end

	def tag_instance_resources(idata)
		cfgtags = @mgr.tags()
		cfgtags["Name"] = @mgr.getparam("iname")
		tags = cfgtags.ltags()

		ilist = idata.map(&:id)
		instances = @resource.instances(instance_ids: ilist)
		#puts "Tags: #{tags}"
		instances.batch_create_tags(tags: tags)

		volumes = []
		ilist.each() do |instance|
			volumes += @resource.instance(instance).block_device_mappings().map() { |b| b.ebs.volume_id() }
		end
		@client.create_tags(resources: volumes, tags: tags)
	end

	def update_dns(instance, wait=false)
		instance = resolve(instance)
		i = @resource.instance(instance)
		unless @mgr.getparam("name")
			i.tags.each() do |tag|
				if tag.key() == "Name"
					iname = tag.value()
					name = iname + "." + @mgr["DNSBase"] + "."
					@mgr.setparam("name", name)
					break
				end
			end
		end
		pub_ip = i.public_ip_address
		priv_ip = i.private_ip_address

		pubzone = @mgr["PublicDNSId"]
		privzone = @mgr["PrivateDNSId"]

		change_ids = []
		if pub_ip and pubzone
			@mgr.setparam("zone_id", pubzone)
			@mgr.setparam("ipaddr", pub_ip)
			change_ids << @mgr.route53.change_records("arec")
		end
		if priv_ip and privzone
			@mgr.setparam("zone_id", privzone)
			@mgr.setparam("ipaddr", priv_ip)
			change_ids << @mgr.route53.change_records("arec")
		end
		if wait
			change_ids.each() { |id| @mgr.route53.wait_sync(id) }
		end
	end
	
	def wait_running(instances)
		instance_list = instances.map(&:id)
		@client.wait_until(:instance_running, instance_ids: instance_list)
	end
end
