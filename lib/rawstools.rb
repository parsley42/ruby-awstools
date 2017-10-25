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
	Expand_Regex = /\${([@=%&][:|.\-\/\w<>]+)}/
  Log_Levels = [:trace, :debug, :info, :warn, :error]

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

	# Central library class that loads the configuration file and provides
  # utility classes for processing names and templates.
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

      @loglevel = Log_Levels.index(:info)
      if @config["LogLevel"] != nil
        ll = @config["LogLevel"].to_sym()
        if Log_Levels.index(ll) != nil
          @loglevel = Log_Levels.index(ll)
        end
      end
      if ENV["RAWS_LOGLEVEL"] != nil
        ll = ENV["RAWS_LOGLEVEL"].to_sym()
        if Log_Levels.index(ll) != nil
          @loglevel = Log_Levels.index(ll)
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

    # Log events, takes a symbol log level (see Log_Levels) and a message.
    # NOTE: eventually there should be a separate configurable log level for
    # stuff that also gets logged to CloudWatch logs.
    def log(level, message)
      ll = Log_Levels.index(level)
      if ll != nil && ll >= @loglevel
        $stderr.puts(message)
      end
    end

		# Implement a simple mutex to prevent collisions. Scripts can use a lock
    # to synchronize updates to the repository.
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

    # Iterate through a data structure and replace all hash string keys
    # with symbols. Ruby AWS API calls all take symbols as their hash keys.
    # Updates the data structure in-place.
		def symbol_keys(item)
      case item.class().to_s()
			when "Hash"
				item.keys().each() do |key|
					if key.class.to_s() == "String"
            oldkey = key
						key = key.to_sym()
						item[key] = item[oldkey]
						item.delete(oldkey)
					end
					symbol_keys(item[key])
				end
			when "Array"
				item.each() { |i| symbol_keys(i) }
			end
		end

    # merge 2nd-level hashes, src overwrites and modifies dst in place
    def merge_templates(src, dst)
      src.keys.each() do |key|
        if ! dst.has_key?(key)
          dst[key] = src[key]
        else
          dst[key] = dst[key].merge(src[key])
        end
      end
    end

    # Load API template files in order from least to most specific; throws an
    # exeption if no specific template with the named type is loaded.
    def load_template(facility, type)
      search_dirs = ["#{@installdir}/templates"] + @config["SearchPath"] + ["."]
      template = {}
      found = false
      search_dirs.each do |dir|
        log(:debug, "Looking for #{dir}/#{facility}/#{facility}.yaml")
        if File::exist?("#{dir}/#{facility}/#{facility}.yaml")
          log(:debug, "=> Loading #{dir}/#{facility}/#{facility}.yaml")
          raw = File::read("#{dir}/#{facility}/#{facility}.yaml")
          merge_templates(YAML::load(raw), template)
        end
        log(:debug, "Looking for #{dir}/#{facility}/#{type}.yaml")
        if File::exist?("#{dir}/#{facility}/#{type}.yaml")
          log(:debug, "=> Loading #{dir}/#{facility}/#{type}.yaml")
          found = true
          raw = File::read("#{dir}/#{facility}/#{type}.yaml")
          merge_templates(YAML::load(raw), template)
        end
      end
      unless found
        raise "Couldn't find a #{facility} template for #{type}"
      end
      return template
    end

    # Take a string of the form ${something} and expand the value from
    # config, sdb, parameters, or cloudformation.
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

    # Iteratively expand all the ${...} values in a string which may be a
    # full CloudFormation YAML template
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

		# Resolve $var, $@var, $%var references to cfg items, no error checking on
    # types, and evaluate and expand all the string values in a template, called
    # by library methods just prior to using a template in an API call.
		def resolve_vars(parent, item)
      log(:trace, "Resolving values for key: #{item}")
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
					end # case cfgvar[0]
        else
          expanded = expand_strings(parent[item])
          log(:trace, "Expanded string \"#{parent[item]}\" -> \"#{expanded}\"")
          parent[item] = expanded
          if parent[item] == "<DELETE>"
            parent.delete(item)
          elsif parent[item] == "<REQUIRED>"
            raise "Missing required value for key #{item}"
          end
				end
			end # case item.class
		end
	end # Class CloudManager

end # Module RAWS
