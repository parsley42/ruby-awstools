# Classes for processing yaml templates into AWS JSON templates

# Convenience class for creating an AWS Outputs hash
class Output
	attr_reader :output

	def initialize(desc, ref)
		@output = { "Description" => desc, "Value" => { "Ref": ref } }
	end
end

class CFTemplate
	attr_reader :name, :outputs, :param_includes

	def initialize(directory, name, cloudcfg, param_includes, parent)
		@name = name
		@cloudcfg = cloudcfg
		@param_includes = param_includes
		@parent = parent
		@st = @cloudcfg["SubnetTypes"]
		@az = @cloudcfg["AvailabilityZones"]
		raw = File::read(directory + "/" + @name.downcase() + ".yaml")
		raw = @cloudcfg.expand_strings(raw)
		puts "Loading #{@name}"
		@cfg = YAML::load(raw)
		@cloudcfg.resolve_vars({ "child" => @cfg }, "child")
		@res = @cfg["Resources"]
		@cfg["Outputs"] ||= {}
		@outputs = @cfg["Outputs"]
	end

	def <=>(other)
		return 0 if ( ! self.param_includes && ! other.param_includes )
		return 1 if  ( self.param_includes && ! other.param_includes )
		return -1 if  ( other.param_includes && ! self.param_includes )
		if other.param_includes.include?(self.name)
			raise "Circular param includes" if self.param_includes.include?(other.name)
			return -1
		elsif self.param_includes.include?(other.name)
			raise "Circular param includes" if other.param_includes.include?(self.name)
			return 1
		else
			return 0
		end
	end

	def write(directory)
		f = File.open(directory + "/" + @name.downcase() + ".json", "w")
		f.write(JSON::pretty_generate(@cfg))
		f.close()
	end

	# If a resource defines a tag, configured tags won't overwrite it
	def update_tags(resource, name=nil, tagkey="Tags")
		cfgtags = @cloudcfg.tags()
		cfgtags["Name"] = name if name
		cfgtags.add(resource["Properties"][tagkey]) if resource["Properties"][tagkey]
		resource["Properties"][tagkey] = cfgtags.tags()
	end

	# Returns an Array of string CIDRs, even if it's only 1 long
	def resolve_cidr(ref)
		clists = @cloudcfg["CIDRLists"]
		if @cloudcfg["SubnetTypes"][ref] != nil
			return [ @cloudcfg["SubnetTypes"][ref].cidr ]
		elsif clists[ref] != nil
			if clists[ref].class == Array
				return clists[ref]
			else
				return [ clists[ref] ]
			end
		else
			raise "Bad configuration item: \"#{ref}\" from #{self.name} not defined in \"CIDRLists\" section of cloudconfig.yaml"
		end
	end

	def process()
		if @param_includes
			@cfg["Parameters"] ||= {}
			params = @cfg["Parameters"]
			@param_includes.each() do |childname|
				other = @parent.find_child(childname)
				other.outputs().each_key() do |output|
					raise "Duplicate parameter (resource name) while processing #{@name}: #{output}" if params[output]
					params[output] = {"Type" => "String"}
				end
			end
		end
		reskeys = @res.keys()
		reskeys.each do |reskey|
			@res[reskey]["Properties"] ||= {}
			case @res[reskey]["Type"]
			# Just tag these
			when "AWS::EC2::InternetGateway", "AWS::EC2::RouteTable", "AWS::EC2::NetworkAcl", "AWS::EC2::Instance", "AWS::EC2::Volume", "AWS::EC2::VPC", "AWS::S3::Bucket"
				update_tags(@res[reskey], reskey)
			when "AWS::Route53::HostedZone"
				update_tags(@res[reskey],nil,"HostedZoneTags")
				@outputs["#{reskey}Id"] = Output.new("Hosted Zone Id for #{reskey}", reskey).output
			when "AWS::EC2::Subnet"
				ref = @res[reskey]["Properties"]["CidrBlock"]
				if ref && ref[0] == '$'
					cfgref = ref[2..-1]
					if @st[cfgref] == nil
						raise "No configured subnet type for \"#{cfgref}\" defined in network template"
					end
					STDERR.puts "WARNING: Resource identifier (#{reskey}) didn't match referenced subnet, using #{cfgref}" if reskey != cfgref
					raw_sn = Marshal.dump(@res[reskey])
					@res.delete(reskey)
					# Generate new subnet definitions for each AZ
					@az.each_index do |i|
						newsn = Marshal.load(raw_sn)
						newsn["Properties"]["CidrBlock"] = @st[cfgref].subnets[i]
						newsn["Properties"]["AvailabilityZone"] = @cloudcfg["Region"] + @az[i]
						sname = cfgref + @az[i].upcase()
						update_tags(newsn, sname)
						@res[sname] = newsn
						@outputs[sname] = Output.new("SubnetId of #{sname} subnet", sname).output
					end
				end
			when "AWS::EC2::SubnetRouteTableAssociation", "AWS::EC2::SubnetNetworkAclAssociation"
				ref = @res[reskey]["Properties"]["SubnetId"]
				if ref && ref[0] == '$'
					cfgref = ref[2..-1]
					assn = @res[reskey]
					@res.delete(reskey)
					if @st[cfgref] == nil
						raise "No configured subnet type for \"#{cfgref}\" defined in network template, referenced in resource #{reskey}"
					end
					# Generate new SubnetRouteTableAssociation definitions for each AZ
					@az.each_index do |i|
						# NOTE: a mere clone() is shallow; using Marshal we can get a deep clone
						raw_assn = Marshal.dump(assn)
						nassn = Marshal.load(raw_assn)
						sname = cfgref + @az[i].upcase()
						nassn["Properties"]["SubnetId"] = { "Ref" => sname }
						assn_name = reskey + @az[i].upcase()
						@res[assn_name] = nassn
					end
				end
			when "AWS::EC2::SecurityGroup"
				update_tags(@res[reskey], reskey)
				@outputs[reskey] = Output.new("#{reskey} security group", reskey).output
				[ "SecurityGroupIngress", "SecurityGroupEgress" ].each() do |sgtype|
					sglist = @res[reskey]["Properties"][sgtype]
					next if sglist == nil
					additions = []
					sglist.delete_if() do |rule|
						next unless rule["CidrIp"]
						next unless rule["CidrIp"][0]=='$'
						cfgref = rule["CidrIp"][2..-1]
						rawrule = Marshal.dump(rule)
						resolve_cidr(cfgref).each() do |cidr|
							newrule = Marshal.load(rawrule)
							newrule["CidrIp"] = cidr
							additions.push(newrule)
						end
						true
					end
					@res[reskey]["Properties"][sgtype] = sglist + additions
				end
			when "AWS::EC2::NetworkAclEntry"
				ref = @res[reskey]["Properties"]["CidrBlock"]
				if ref && ref[0] == '$'
					cfgref = ref[2..-1]
					cidr_arr = resolve_cidr(cfgref)
					if cidr_arr.length == 1
						@res[reskey]["Properties"]["CidrBlock"] = cidr_arr[0]
					else
						raw_acl = Marshal.dump(@res[reskey])
						@res.delete(reskey)
						cidr_arr.each_index do |i|
							newacl = Marshal.load(raw_acl)
							prop = newacl["Properties"]
							prop["RuleNumber"] = prop["RuleNumber"].to_i + i
							prop["CidrBlock"] = cidr_arr[i]
							aclname = reskey + i.to_s
							@res[aclname] = newacl
						end
					end
				end
			when "AWS::CloudFormation::Stack"
				if @name != "main"
					raise "Child stacks must be in main.json"
				end
				@res[reskey]["Properties"] ||= {}
				if @res[reskey]["Properties"]["Parameters"]
					param_includes = @res[reskey]["Properties"]["Parameters"]["Includes"]
					@res[reskey]["Properties"]["Parameters"].delete("Includes") if param_includes
				end
				update_tags(@res[reskey], reskey)
				childname = reskey.chomp("Stack")
				@res[reskey]["Properties"]["TemplateURL"] = [ "https://s3.amazonaws.com", @cloudcfg["Bucket"], @cloudcfg["Prefix"], @templatename, childname.downcase() + ".json" ].join("/")
				@outputs[reskey] = Output.new("#{reskey} child stack", reskey).output
				@children.push(CFTemplate.new(@directory, childname, @cloudcfg, param_includes, self))
			end # case
		end
	end
end

class MainTemplate < CFTemplate
	attr_reader :children

	def initialize(directory, templatename, cloudcfg)
		@templatename = templatename
		@children = []
		@directory = directory
		super(directory, "main", cloudcfg, nil, nil)
	end

	def process_children()
		# If one child lists another in it's parameter_includes, it sorts higher
		@children.sort!()
		@children.each() do |child|
			child.process()
			if child.param_includes
				@res[child.name()+"Stack"]["Properties"]["Parameters"] ||= {}
				params = @res[child.name()+"Stack"]["Properties"]["Parameters"]
				child.param_includes.each() do |param_include|
					param_child = find_child(param_include)
					param_child.outputs.each_key() do |output|
						raise "Duplicate parameter: #{output}" if params[output]
						params[output] = { "Fn::GetAtt" => [ "#{param_include}Stack", "Outputs.#{output}" ] }
					end
				end
			end
		end
	end

	def find_child(childname)
		index = @children.map {|child| child.name() }.index(childname)
		raise "Reference to unknown child template: #{childname}" unless index
		@children[index]
	end

	def write_all(directory)
		self.write(directory)
		@children.each() {|child| child.write(directory) }
	end
end
