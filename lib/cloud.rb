require 'base64'

module RAWSTools
	load "lib/ec2.rb"
	load "lib/route53.rb"
	load "lib/cloudformation.rb"

	# Classes for loading and processing the configuration file
	Valid_Classes = [ "String", "Fixnum", "TrueClass", "FalseClass" ]

	class SubnetDefinition
		attr_reader :cidr, :subnets

		def initialize(cidr, subnets)
			@cidr = cidr
			@subnets = subnets
		end
	end

	# Class to convert from configuration file format to AWS expected format
	# for tags
	class Tags
		def initialize(cfg)
			@tags = Marshal.load(Marshal.dump(cfg["Tags"])) if cfg["Tags"]
			@tags ||= {}
		end

		def tags()
			tags = []
			@tags.each_key do |k|
				tags.push({ "Key" => k, "Value" => @tags[k] })
			end
			return tags
		end

		# Bucket tags have lowercase 
		def ltags()
			tags = []
			@tags.each_key do |k|
				tags.push({ "key" => k, "value" => @tags[k] })
			end
			return tags
		end

		def []=(key, value)
			@tags[key] = value
		end

		def add(hash)
			@tags = @tags.merge(hash)
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
			[ "DNSBase", "DNSDomain", "ConfigDom" ].each do |dnsdom|
				name = @config[dnsdom]
				if name.end_with?(".")
					STDERR.puts("Warning: removing trailing dot from #{dnsdom}")
					@config[dnsdom] = name[0..-2]
				end
			end
			subnet_types = {}
			@config["SubnetTypes"].each_key do |st|
				subnet_types[st] = SubnetDefinition.new(@config["SubnetTypes"][st]["CIDR"], @config["SubnetTypes"][st]["Subnets"])
			end
			@config["SubnetTypes"] = subnet_types

			@ec2 = Ec2.new(self)
			@cfn = CloudFormation.new(self)
			@s3 = Aws::S3::Client.new( region: @config["Region"] )
			@s3res = Aws::S3::Resource.new( client: @s3 )
			@route53 = Route53.new(self)
		end

		def tags()
			return Tags.new(self)
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

		def expand_strings(rawdata)
			data = rawdata
			while data.match(/\${[@=:%$.\w]+}/)
				data = data.gsub(/\${([@=:%$.\w]+)}/) do |ref|
					var = $1
					#puts "Expanding #{ref}, var is #{var}"
					case var[0]
					when "@"
						param, default = var.split(':')
						param = param[1..-1]
						value = getparam(param)
						if value
							value
						elsif default
							if default[0] == "$"
								cfgvar = default[1..-1]
								if @config[cfgvar] == nil
									raise "Invalid default for \"#{var}\": \"#{cfgvar}\" not defined in #{@filename}"
								end
								varclass = @config[cfgvar].class().to_s()
								unless Valid_Classes.include?(varclass)
									raise "Bad default value for \"#{var}\" during string expansion: \"$#{cfgvar}\" expands to non-scalar class #{varclass}"
								end
								@config[cfgvar]
							else
								default
							end
						else
							raise "Reference to undefined parameter: \"#{param}\""
						end
					when "="
						output = var[1..-1]
						value = @cfn.getoutput(output)
						raise "Output not found while expanding \"#{var}\"" unless value
						value
					when "%"
						record = var[1..-1]
						suffix = @config["ConfigDom"]
						suffix = "." + suffix unless suffix.start_with?(".")
						record = record + suffix unless record.end_with?(suffix)
						record = record + "." unless record.end_with?(".")
						values = @route53.lookup(record, @config["PrivateDNSId"])
						raise "Failed to receive single-value record looking up \"#{record}\" in #{suffix}" unless values.length == 1
						value = values[0]
						trim = '"'
						value = value[1..-1] if value.start_with?(trim)
						value = value[0..-2] if value.end_with?(trim)
						value
					else
						if @config[var] == nil
							raise "Bad variable reference: \"#{var}\" not defined in #{@filename}"
						end
						varclass = @config[var].class().to_s()
						unless Valid_Classes.include?(varclass)
							raise "Bad variable reference during string expansion: \"$#{var}\" expands to non-scalar class #{varclass}"
						end
						@config[var]
					end
				end
			end
			return data
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
					cfgvar = var[1..-1]
					case cfgvar[0]
					when "@"
						param = cfgvar[1..-1]
						value = getparam(param)
						raise "Reference to undefined parameter \"#{param}\" during data element expansion of \"#{var}\"" unless value
						parent[item] = value
					when "%"
						record = cfgvar[1..-1]
						record = record + cfgdom unless record.end_with?(cfgdom)
						values = @route53.lookup(record, :private)
						raise "No values returned from lookup of #{record}" unless values.length > 0
						parent[item] = values
					else
						if @config[cfgvar] == nil
							raise "Bad variable reference: \"#{cfgvar}\" not defined in #{@filename}"
						end
						parent[item] = @config[cfgvar]
					end
				end
			end # case item.class
		end
	end # Class CloudManager

end # Module RAWS
