class Ec2
	attr_reader :client, :resource

	def initialize(cloudmgr)
		@mgr = cloudmgr
		@client = Aws::EC2::Client.new( region: @mgr["Region"] )
		@resource = Aws::EC2::Resource.new(client: @client)
	end

	def create_from_template(template)
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
		puts "Creating: #{ispec}"

		instances = @resource.create_instances(ispec)
		return instances
	end
	
	def wait_running(instances)
		instance_list = instances.map(&:id)
		@client.wait_until(:instance_running, instance_ids: instance_list)
	end
end
