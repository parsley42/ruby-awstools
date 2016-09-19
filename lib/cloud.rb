
module RAWSTools
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

	class Ec2
		attr_reader :client, :resource

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::EC2::Client.new( region: @mgr["Region"] )
			@resource = Aws::EC2::Resource.new(client: @client)
		end

		def create_from_template(template)

		end
	end

	load "lib/route53.rb"

	class CloudFormation
		attr_reader :client, :resource

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::CloudFormation::Client.new( region: @mgr["Region"] )
			@resource = Aws::CloudFormation::Resource.new( client: @client )
			@outputs = {}
		end

		def validate(template, verbose=true)
			resp = @client.validate_template({ template_body: template })
			if verbose
				puts "Description: #{resp.description}"
				if resp.capabilities.length > 0
					puts "Capabilities: #{resp.capabilities.join(",")}"
					puts "Reason: #{resp.capabilities_reason}"
				end
				puts
			end
			return resp.capabilities
		end

		def list_stacks()
			stacklist = []
			stack_states = [ "CREATE_IN_PROGRESS", "CREATE_FAILED", "CREATE_COMPLETE", "ROLLBACK_IN_PROGRESS", "ROLLBACK_FAILED", "ROLLBACK_COMPLETE", "DELETE_IN_PROGRESS", "DELETE_FAILED", "UPDATE_IN_PROGRESS", "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_IN_PROGRESS", "UPDATE_ROLLBACK_FAILED", "UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS", "UPDATE_ROLLBACK_COMPLETE" ]
			@resource.stacks().each() do |stack|
				status = stack.stack_status
				next unless stack_states.include?(status)
				stacklist << stack.stack_name
			end
			return stacklist
		end

		def getoutputs(outputsspec)
			parent, child = outputsspec.split(':')
			prefix = @mgr["StackPrefix"]
			if prefix
				parent = prefix + parent unless parent.start_with?(prefix)
			end
			if @outputs[parent]
				outputs = @outputs[parent]
			else
				stack = @resource.stack(parent)
				outputs = {}
				@outputs[parent] = outputs
				stack.outputs().each() do |output|
					outputs[output.output_key] = output.output_value
				end
			end
			if child
				child = child + "Stack" unless child.end_with?("Stack")
				childstack = outputs[child].split('/')[1]
				if @outputs[childstack]
					outputs = @outputs[childstack]
				else
					outputs = getoutputs(childstack)
				end
			end
			outputs
		end

		def getoutput(outputspec)
			terms = outputspec.split(':')
			child = nil
			if terms.length == 2
				stackname, output = terms
			else
				stackname, child, output = terms
			end
			if child
				outputs = getoutputs("#{stackname}:#{child}")
			else
				outputs = getoutputs(stackname)
			end
			return outputs[output]
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

			@ec2 = Ec2.new(self)
			@cfn = CloudFormation.new(self)
			@s3 = Aws::S3::Client.new( region: @config["Region"] )
			@s3res = Aws::S3::Resource.new( client: @s3 )
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

		def expand_strings(rawdata)
			rawdata.gsub(/\${([@=:%$\w]+)}/) do |ref|
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
				when "%"
					cfgdom = @config["ConfigDom"]
					record = var[1..-1]
					record = record + cfgdom unless record.end_with?(cfgdom)
					values = @route53.lookup(record, :private)
					raise "Failed to receive single-value record looking up \"#{record}\" in #{cfgdom}" unless values.length == 1
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
