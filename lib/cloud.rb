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
			@route53 = Aws::Route53::Client.new( region: @mgr["Region"] )
		end

		def r53_set(where, template)
			templatefile = nil
			if File::exist?("#{template}.json")
				templatefile = "#{template}.json"
			else
				templatefile = "#{@installdir}/defaults/route53/#{template}.json"
			end
			set = YAML::load(File::read(templatefile))
			case where
			when :public
				set["hosted_zone_id"] = @config["PublicDNSId"]
			when :private
				set["hosted_zone_id"] = @config["PrivateDNSId"]
			end
			resolve_vars( { "child" => set }, "child" )
		end
	end

	# For reading in the configuration file and initializing service clients
	# and resources
	class CloudManager
		attr_reader :installdir, :cfn, :cfnres, :s3, :ec2, :ec2res, :route53

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
			@cfnres = Aws::CloudFormation::Resource.new( client: cfn )
			@s3 = Aws::S3::Resource.new( region: @config["Region"] )
			@ec2 = Aws::EC2::Client.new( region: @config["Region"] )
			@ec2res = Aws::EC2::Resource.new(client: @ec2)
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

		def resolve_value(var)
			cfgvar = var[1..-1]
			case cfgvar[0]
			when "@"
				return get(cfgvar[1..-1])
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
