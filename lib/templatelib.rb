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
		puts "Loading #{@name}"
		@cfg = YAML::load(raw)
		@res = @cfg["Resources"]
		@cfg["Outputs"] ||= {}
		@outputs = @cfg["Outputs"]
	end

	def <=>(other)
		#DEBUG
		#puts "Comparing #{self.name}:"
		#puts self.param_includes
		#puts "to #{other.name}:"
		#puts other.param_includes
		#puts
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
	end

	# If a resource defines a tag, configured tags won't overwrite it
	def merge_tags(resource, tagkey="Tags")
		cfgtags = @cloudcfg["Tags"]
		if resource["Properties"][tagkey] == nil
			resource["Properties"][tagkey] = cfgtags
			return
		end
		restags = resource["Properties"][tagkey]
		reskeys = []
		restags.each() do |tag|
			reskeys.push(tag["Key"])
		end
		cfgtags.each do |cfgtag|
			if ! reskeys.include?(cfgtag["Key"])
				restags.push(cfgtag)
			end
		end
	end

	# Resolve $var references to cfg items, no error checking on types
	def resolve_ref(item, key)
		ref = item[key]["Ref"]
		if ref == nil
			return
		end
		if ref[0] == '$'
			cfgref = ref[1..-1]
			if @cloudcfg[cfgref] == nil
				raise "Bad reference: \"#{cfgref}\" not defined in cloudconfig.yaml"
			end
			item[key] = @cloudcfg[cfgref]
		end
	end	

	# Returns an Array of string CIDRs, even if it's only 1 long
	def resolve_cidr(ref)
		if @cloudcfg["SubnetTypes"][ref] != nil
			return [ @cloudcfg["SubnetTypes"][ref].cidr ]
		elsif @cloudcfg[ref] != nil
			if @cloudcfg[ref].class == Array
				return @cloudcfg[ref]
			else
				return [ @cloudcfg[ref] ]
			end
		else
			raise "Bad configuration item: \"#{ref}\" not defined in cloudconfig.yaml"
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
			when "AWS::EC2::InternetGateway", "AWS::EC2::RouteTable", "AWS::EC2::NetworkAcl"
				merge_tags(@res[reskey])
			when "AWS::EC2::VPC"
				merge_tags(@res[reskey])
				@res[reskey]["Properties"]["CidrBlock"] = @cloudcfg["VPCCIDR"]
			when "AWS::S3::Bucket"
				merge_tags(@res[reskey])
				resolve_ref(@res[reskey]["Properties"], "BucketName")
			when "AWS::Route53::HostedZone"
				merge_tags(@res[reskey],"HostedZoneTags")
				resolve_ref(@res[reskey]["Properties"], "Name")
			when "AWS::EC2::Subnet"
				if @st[reskey] == nil
					raise "No configured subnet type for \"#{reskey}\" defined in network template"
				end
				merge_tags(@res[reskey])
				raw_sn = Marshal.dump(@res[reskey])
				@res.delete(reskey)
				# Generate new subnet definitions for each AZ
				@az.each_index do |i|
					newsn = Marshal.load(raw_sn)
					newsn["Properties"]["CidrBlock"]=@st[reskey].subnets[i]
					sname = reskey + @az[i].upcase()
					@res[sname] = newsn
					@outputs[sname] = Output.new("SubnetId of #{sname} subnet", sname).output
				end
			when "AWS::EC2::SecurityGroup"
				merge_tags(@res[reskey])
				@outputs[reskey] = Output.new("#{reskey} security group", reskey).output
				[ "SecurityGroupIngress", "SecurityGroupEgress" ].each() do |sgtype|
					sglist = @res[reskey]["Properties"][sgtype]
					next if sglist == nil
					additions = []
					sglist.delete_if() do |rule|
						next unless rule["CidrIp"]["Ref"]
						next unless rule["CidrIp"]["Ref"][0]='$'
						ref = rule["CidrIp"]["Ref"][1..-1]
						rawrule = Marshal.dump(rule)
						resolve_cidr(ref).each() do |cidr|
							newrule = Marshal.load(rawrule)
							newrule["CidrIp"] = cidr
							additions.push(newrule)
						end
						true
					end
					@res[reskey]["Properties"][sgtype] = sglist + additions
				end
			when "AWS::EC2::NetworkAclEntry"
				ref = @res[reskey]["Properties"]["CidrBlock"]["Ref"]
				if ref == nil
					next
				end
				if ref[0] == '$'
					cfgref = ref[1..-1]
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
							prop["CidrBlock"] = @cloudcfg[cfgref][i]
							aclname = reskey + i.to_s
							@res[aclname] = newacl
						end
					end
				end
			when "AWS::EC2::SubnetRouteTableAssociation", "AWS::EC2::SubnetNetworkAclAssociation"
				assn = @res[reskey]
				@res.delete(reskey)
				sn = assn["Properties"]["SubnetId"]["Ref"]
				if @st[sn] == nil
					raise "No configured subnet type for \"#{sn}\" defined in network template, reference in resource #{reskey}"
				end
				# Generate new SubnetRouteTableAssociation definitions for each AZ
				@az.each_index do |i|
					# NOTE: a mere clone() is shallow; using Marshal we can get a deep clone
					raw_assn = Marshal.dump(assn)
					nassn = Marshal.load(raw_assn)
					sname = sn + @az[i].upcase()
					nassn["Properties"]["SubnetId"]["Ref"] = sname
					assn_name = reskey + @az[i].upcase()
					@res[assn_name] = nassn
				end
			when "AWS::CloudFormation::Stack"
				if @name != "main"
					raise "Child stacks must be in main.json"
				end
				@res[reskey]["Properties"] ||= {}
				if @res[reskey]["Properties"]["Parameters"]
					param_includes = @res[reskey]["Properties"]["Parameters"]["Includes"]
				end
				merge_tags(@res[reskey])
				childname = reskey.chomp("Stack")
				@res[reskey]["Properties"]["TemplateURL"] = [ "https://s3.amazonaws.com", @cloudcfg["Bucket"], @cloudcfg["Prefix"], @directory, childname.downcase() + ".json" ].join("/")
				@outputs[reskey] = Output.new("#{reskey} child stack", reskey).output
				@children.push(CFTemplate.new(@directory, childname, @cloudcfg, param_includes, self))
			end # case
		end
	end
end

class MainTemplate < CFTemplate
	attr_reader :children

	def initialize(directory, cloudcfg)
		@children = []
		@directory = directory
		super(directory, "main", cloudcfg, nil, nil)
	end

	def process_children()
		# If one child lists another in it's parameter_includes, it sorts higher
		@children.sort!()
		# DEBUT
		#puts "Sorted:"
		#puts @children.map() { |child| child.name }
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
