module RAWSTools
	# Classes for loading and processing the configuration file

	class SubnetDefinition
		attr_reader :cidr, :subnets

		def initialize(cidr, subnets)
			@cidr = cidr
			@subnets = subnets
		end
	end

	# Class to convert from configuration file format to AWS expected format
	# for tags
	class CfgTags
		attr_reader :output, :loweroutput

		def initialize(tags)
			@output = []
			@loweroutput = []
			tags.each do |hash|
				hash.each_key do |k|
					@output.push({ "Key" => k, "Value" => hash[k] })
					@loweroutput.push({ "key" => k, "value" => hash[k] })
				end
			end
		end
	end

	class Route53
		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::Route53::Client.new( region: @mgr["Region"] )
		end

		def change_records(where, template, wait = false)
			templatefile = nil
			if File::exist?("#{template}.json")
				templatefile = "#{template}.json"
			else
				templatefile = "#{@mgr.installdir}/defaults/route53/#{template}.yaml"
			end
			set = YAML::load(File::read(templatefile))

			name = @mgr.getparam("name")
			if not name.end_with?(@mgr["DNSDomain"])
				@mgr.setparam("name", "#{name}.#{@mgr["DNSDomain"]}")
			end
			cname = @mgr.getparam("cname")
			if cname and not cname.end_with?(@mgr["DNSDomain"])
				@mgr.setparam("cname", "#{cname}.#{@mgr["DNSDomain"]}")
			end

			@mgr.resolve_vars( { "child" => set }, "child" )
			@mgr.symbol_keys(set)

			if where == :public or where == :both
				set[:hosted_zone_id] = @mgr["PublicDNSId"]
				pubresp = @client.change_resource_record_sets(set)
			end
			if where == :private or where == :both
				set[:hosted_zone_id] = @mgr["PrivateDNSId"]
				privresp = @client.change_resource_record_sets(set)
			end

			return unless wait

			if where == :public or where == :both
				@client.wait_until(:resource_record_sets_changed, id: pubresp.change_info.id )
			end
			if where == :private or where == :both
				@client.wait_until(:resource_record_sets_changed, id: privresp.change_info.id )
			end
		end
	end

	# For reading in the configuration file and initializing service clients
	# and resources
	class CloudManager
		attr_reader :installdir, :cfn, :cfnres, :s3, :s3res, :ec2, :ec2res, :route53

		def initialize(filename, installdir)
			@filename = filename
			@installdir = installdir
			@params = {}

			@config = YAML::load(File::read(filename))
			[ "Bucket", "Region", "VPCCIDR", "AvailabilityZones", "SubnetTypes" ].each do |c|
				if ! @config[c]
					raise "Missing required top-level configuration item in #{@filename}: #{c}"
				end
			end
			subnet_types = {}
			@config["SubnetTypes"].each_key do |st|
				subnet_types[st] = SubnetDefinition.new(@config["SubnetTypes"][st]["CIDR"], @config["SubnetTypes"][st]["Subnets"])
			end
			@config["SubnetTypes"] = subnet_types

			tags = CfgTags.new(@config["Tags"])
			@config["Tags"] = tags.output
			@config["tags"] = tags.loweroutput

			@cfn = Aws::CloudFormation::Client.new( region: @config["Region"] )
			@cfnres = Aws::CloudFormation::Resource.new( client: @cfn )
			@s3 = Aws::S3::Client.new( region: @config["Region"] )
			@s3res = Aws::S3::Resource.new( client: @s3 )
			@ec2 = Aws::EC2::Client.new( region: @config["Region"] )
			@ec2res = Aws::EC2::Resource.new(client: @ec2)
			@route53 = Route53.new(self)
		end

		def setparams(hash)
			@params = hash
		end

		def setparam(param, value)
			@params[param] = value
		end

		def getparam(param)
			@params[param]
		end

		def [](key)
			@config[key]
		end

		def symbol_keys(item)
			case item.class().to_s()
			when "Hash"
				keys = item.keys()
				keys.each() do |key|
					if key.class.to_s() == "String"
						symkey = key.to_sym()
						item[symkey] = item[key]
						item.delete(key)
					end
					symbol_keys(item[symkey])
				end
			when "Array"
				item.each() { |i| symbol_keys(i) }
			end
		end

		def resolve_value(var)
			cfgvar = var[1..-1]
			case cfgvar[0]
			when "@"
				return getparam(cfgvar[1..-1])
			else
				if @config[cfgvar] == nil
					raise "Bad variable reference: \"#{cfgvar}\" not defined in #{@filename}"
				end
				return @config[cfgvar]
			end
		end

		# Resolve $var references to cfg items, no error checking on types
		def resolve_vars(parent, item)
			case parent[item].class().to_s()
			when "Array"
				parent[item].each_index() do |index|
					resolve_vars(parent[item], index)
				end
			when "Hash"
				parent[item].each_key() do |key|
					resolve_vars(parent[item], key)
				end # Hash each
			when "String"
				var = parent[item]
				if var[0] == '$' && var[1] != '$'
					parent[item] = resolve_value(var)
				end
			end # case item.class
		end
	end # Class CloudManager

end # Module RAWS
