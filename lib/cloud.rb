require 'base64'

module RAWSTools
	load "lib/ec2.rb"
	load "lib/route53.rb"
	load "lib/cloudformation.rb"

	# Classes for loading and processing the configuration file
	Valid_Classes = [ "String", "Fixnum", "TrueClass", "FalseClass" ]
	Expand_Regex = /\${([@=%&][|.\/\w]+)}/

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
		attr_reader :installdir, :subdom, :cfgsubdom, :cfn, :s3, :s3res, :ec2, :route53

		def initialize(filename, installdir)
			@filename = filename
			@installdir = installdir
			@params = {}
			@subdom = nil
			@cfgsubdom = nil

			raw = File::read(filename)
			# A number of config items need to be defined before using expand_strings
			@config = YAML::load(raw)
			raw = expand_strings(raw)
			# Now replace config with expanded version
			@config = YAML::load(raw)

			[ "Bucket", "Region", "VPCCIDR", "AvailabilityZones", "SubnetTypes" ].each do |c|
				if ! @config[c]
					raise "Missing required top-level configuration item in #{@filename}: #{c}"
				end
			end

			[ "DNSBase", "DNSDomain", "ConfigDomain" ].each do |dnsdom|
				name = @config[dnsdom]
				if name.end_with?(".")
					STDERR.puts("Warning: removing trailing dot from #{dnsdom}")
					@config[dnsdom] = name[0..-2]
				end
				if name.start_with?(".")
					STDERR.puts("Warning: removing leading dot from #{dnsdom}")
					@config[dnsdom] = name[1..-1]
				end
			end
			raise "Invalid configuration, ConfigDomain not a subdomain of DNSBase" unless @config["ConfigDomain"].end_with?(@config["DNSBase"])
			raise "Invalid configuration, DNSDomain same as or subdomain of DNSBase" unless @config["DNSDomain"].end_with?(@config["DNSBase"])
			if @config["DNSDomain"] != @config["DNSBase"]
				i = @config["DNSDomain"].index(@config["DNSBase"])
				@subdom = @config["DNSDomain"][0..(i-2)]
			end
			if @config["ConfigDomain"] != @config["DNSBase"]
				i = @config["ConfigDomain"].index(@config["DNSBase"])
				@cfgsubdom = @config["ConfigDomain"][0..(i-2)]
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

		def normalize_name_parameters()
			domain = @config["DNSDomain"]
			cfgdom = @config["ConfigDomain"]
			base = @config["DNSBase"]
			# NOTE: skipping 'snapname' for now, since they will likely
			# be of the form <name>-<timestamp>
			["name", "cname", "volname"].each() do |name|
				norm = getparam(name)
				next unless norm
				norm = norm[0..-2] if norm.end_with?(".")
				if norm.end_with?(domain)
					fqdn = norm + "."
					i = norm.index(base)
					norm = norm[0..(i-2)]
				elsif norm.end_with?(cfgdom)
					fqdn = norm + "."
					i = norm.index(cfgdom)
					norm = norm[0..(i-2)]
				elsif @cfgsubdom and norm.end_with?(@cfgsubdom)
					fqdn = norm + "." + base + "."
				elsif @subdom and norm.end_with?(@subdom)
					fqdn = norm + "." + base + "."
				elsif @subdom
					fqdn = norm + "." + domain
					norm = norm + "." + @subdom
				else
					fqdn = norm + "." + domain
				end
				setparam(name, norm)
				case name
				when "name"
					setparam("fqdn", fqdn)
				when "cname"
					setparam("cfqdn", fqdn)
				when "volname"
					setparam("vfqdn", fqdn)
				when "snapname"
					setparam("sfqdn", fqdn)
				end
			end
			az = getparam("az")
			if az
				setparam("az", az.upcase())
				setparam("availability_zone", @config["Region"] + az.downcase())
			end
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

		def getparams(*p)
			r = []
			p.each() { |k| r << @params[k] }
			return r
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

		def expand_string(var)
			var = $1 if var.match(Expand_Regex)
			case var[0]
			when "@"
				param, default = var.split('|')
				param = param[1..-1]
				value = getparam(param)
				if value
					return value
				elsif default
					return default
				else
					raise "Reference to undefined parameter: \"#{param}\""
				end
			when "="
				lookup, default = var.split('|')
				output = lookup[1..-1]
				value = @cfn.getoutput(output)
				if value
					return value
				elsif default
					return default
				else
					raise "Output not found while expanding \"#{var}\"" unless value
				end
			when "%"
				lookup, default = var.split('|')
				record = "#{lookup[1..-1]}.#{@config["ConfigDomain"]}."
				values = @route53.lookup(@config["PrivateDNSId"], record)
				if values.length == 1
					value = values[0]
					trim = '"'
					value = value[1..-1] if value.start_with?(trim)
					value = value[0..-2] if value.end_with?(trim)
					return value
				elsif default
					return default
				else
					raise "Failed to receive single-value record looking up \"#{record}\" in #{@config["ConfigDomain"]}" unless values.length == 1
				end
			when "&"
				cfgvar = var[1..-1]
				if @config[cfgvar] == nil
					raise "Bad variable reference: \"#{cfgvar}\" not defined in #{@filename}"
				end
				varclass = @config[cfgvar].class().to_s()
				unless Valid_Classes.include?(varclass)
					raise "Bad variable reference during string expansion: \"$#{cfgvar}\" expands to non-scalar class #{varclass}"
				end
				return @config[cfgvar]
			end
		end

		def expand_strings(data)
			while data.match(Expand_Regex)
				data = data.gsub(Expand_Regex) do
					expand_string($1)
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
				if var[0] == '$' and var[1] != '$' and var[1] != '{'
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
