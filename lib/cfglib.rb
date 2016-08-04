# Classes for loading and processing the configuration file

# For reading in the configuration file
class ConfigFile
	def initialize(filename)
		@config = YAML::load(File::read(filename))
		[ "Bucket", "OrgCIDRs", "VPCCIDR", "Region", "AvailabilityZones", "SubnetTypes" ].each do |c|
			if ! @config[c]
				raise "Missing top-level configuration item in #{filename}: #{c}"
			end
		end
	end

	def process
		subnet_types = {}
		@config["SubnetTypes"].each_key do |st|
			subnet_types[st] = SubnetDefinition.new(@config["SubnetTypes"][st]["CIDR"], @config["SubnetTypes"][st]["Subnets"])
		end
		@config["SubnetTypes"] = subnet_types

		tags = CfgTags.new(@config["Tags"])
		@config["Tags"] = tags.output
		@config["tags"] = tags.loweroutput

		@config
	end
end

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
