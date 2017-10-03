require 'base64'
require 'yaml'
require 'pathname'
require 'aws-sdk'
require 'rawstools/cloudformation'
require 'rawstools/ec2'
require 'rawstools/rds'
require 'rawstools/route53'
require 'rawstools/simpledb'
require 'rawstools/templatelib'

module RAWSTools
	# Classes for loading and processing the configuration file
	Valid_Classes = [ "String", "Fixnum", "Integer", "TrueClass", "FalseClass" ]
	Expand_Regex = /\${([@=%&][:|.\-\/\w]+)}/

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
		attr_reader :tags

		def initialize(cfg)
			@tags = Marshal.load(Marshal.dump(cfg["Tags"])) if cfg["Tags"]
			@tags ||= {}
		end

		# Tags for API calls
		def apitags()
			tags = []
			@tags.each_key do |k|
				tags.push({ :key => k, :value => @tags[k] })
			end
			return tags
		end

		# Cloudformation template tags
		def cfntags()
			tags = []
			@tags.each_key do |k|
				tags.push({ "Key" => k, "Value" => @tags[k] })
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
		attr_reader :installdir, :subdom, :cfn, :sdb, :s3, :s3res, :ec2, :rds, :route53, :tags, :params

		def initialize(filename)
			@filename = filename
			@installdir = File.dirname(Pathname.new(__FILE__).realpath) + "/rawstools"
			@params = {}
			@subdom = nil
			@file = File::open(filename)
			raw = @file.read()
			# A number of config items need to be defined before using expand_strings
			@config = YAML::load(raw)
			@ec2 = Ec2.new(self)
			@cfn = CloudFormation.new(self)
			@sdb = SimpleDB.new(self)
			@s3 = Aws::S3::Client.new( region: @config["Region"] )
			@s3res = Aws::S3::Resource.new( client: @s3 )
			@rds = RDS.new(self)
			@route53 = Route53.new(self)
			@tags = Tags.new(self)
			raw = expand_strings(raw)
			# Now replace config with expanded version
			#puts "Expanded:\n#{raw}"
			@config = YAML::load(raw)

			[ "Region", "AvailabilityZones" ].each do |c|
				if ! @config[c]
					raise "Missing required top-level configuration item in #{@filename}: #{c}"
				end
			end

			[ "DNSBase", "DNSDomain" ].each do |dnsdom|
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
			raise "Invalid configuration, DNSDomain same as or subdomain of DNSBase" unless @config["DNSDomain"].end_with?(@config["DNSBase"])
			if @config["DNSDomain"] != @config["DNSBase"]
				i = @config["DNSDomain"].index(@config["DNSBase"])
				@subdom = @config["DNSDomain"][0..(i-2)]
			end

			subnet_types = {}
			if @config["SubnetTypes"]
				@config["SubnetTypes"].each_key do |stack|
					subnet_types[stack] = {}
					@config["SubnetTypes"][stack].each_key do |st|
						subnet_types[stack][st] = SubnetDefinition.new(@config["SubnetTypes"][stack][st]["CIDR"], @config["SubnetTypes"][stack][st]["Subnets"])
					end
				end
				@config["SubnetTypes"] = subnet_types
			end
		end

		# Implement a simple mutex to prevent collisions
		def lock()
			@file.flock(File::LOCK_EX)
		end

		def unlock()
			@file.flock(File::LOCK_UN)
		end

		def timestamp()
			now = Time.new()
			return now.strftime("%Y%m%d%H%M")
		end

		def normalize_name_parameters()
			domain = @config["DNSDomain"]
			base = @config["DNSBase"]
			# NOTE: skipping 'snapname' for now, since they will likely
			# be of the form <name>-<timestamp>
			["name", "cname", "volname"].each() do |name|
				norm = getparam(name)
				next unless norm
				if norm.end_with?(".")
					fqdn = norm
				else
					if norm.end_with?(domain)
						fqdn = norm + "."
						i = norm.index(base)
						norm = norm[0..(i-2)]
					elsif @subdom and norm.end_with?(@subdom)
						fqdn = norm + "." + base + "."
					elsif @subdom
						fqdn = norm + "." + domain
						norm = norm + "." + @subdom
					else
						fqdn = norm + "." + domain
					end
				end
				setparam(name, norm)
				case name
				when "name"
					setparam("fqdn", fqdn)
					dbname = norm.gsub(".","-")
					setparam("dbname", dbname)
					ansible_name = norm.gsub(/[.-]/, "_")
					setparam("ansible_name", ansible_name)
				when "cname"
					setparam("cfqdn", fqdn)
				end
			end
			az = getparam("az")
			if az
				setparam("az", az.upcase())
				setparam("availability_zone", @config["Region"] + az.downcase())
			end
		end

		# Convience method for quickly normalizing a name
		def normalize(name, param="name")
			@params[param] = name
			normalize_name_parameters()
			return @params[param]
		end

		def setparams(hash)
			@params = hash
		end

		def setparam(param, value)
			@params[param] = value
		end

		def getparam(param)
			return @params[param]
		end

		def getparams(*p)
			r = []
			p.each() { |k| r << @params[k] }
			return r
		end

		def [](key)
			return @config[key]
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
				if not default and var.end_with?('|')
					default=""
				end
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
				if not default and var.end_with?('|')
					default=""
				end
				output = lookup[1..-1]
				value = @cfn.getoutput(output)
				if value
					return value
				elsif default
					return default
				else
					raise "Output not found while expanding \"#{var}\""
				end
			when "%"
				lookup, default = var.split('|')
				if not default and var.end_with?('|')
					default=""
				end
				lookup = lookup[1..-1]
				item, key = lookup.split(":")
				raise "Invalid SimpleDB lookup: #{lookup}" unless key
				values = @sdb.retrieve(item, key)
				if values.length == 1
					value = values[0]
					return value
				elsif values.length == 0 and default
					return default
				else
					raise "Failed to receive single-value retrieving attribute \"#{key}\" from item #{item} in SimpleDB domain #{@sdb.getdomain()}, got: #{values}"
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
			# NOTE: previous code to remove comments has been removed; it was removing
			# the comment at the top of user_data, which broke user data.
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
						lookup = cfgvar[1..-1]
						item, key = lookup.split(":")
						raise "Invalid SimpleDB lookup: #{lookup}" unless key
						values = @sdb.retrieve(item, key)
						raise "No values returned from lookup of #{key} in item #{item} from #{@sdb.getdomain()}" unless values.length > 0
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
