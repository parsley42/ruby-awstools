module RAWSTools
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
      prefix = @mgr.stack_family
      if prefix
        parent = prefix + parent unless parent.start_with?(prefix)
      end
      if @outputs[parent]
        outputs = @outputs[parent]
      else
        stack = @resource.stack(parent)
        outputs = {}
        @outputs[parent] = outputs
        tries = 0
        while true
          begin
            if stack.exists?()
              stack.outputs().each() do |output|
                outputs[output.output_key] = output.output_value
              end
            end
            break
          rescue => e
            if /rate exceed/i =~ e.message
              tries += 1
              if tries >= 4
                raise e
              end
              sleep 2 * tries
            else
              raise e
            end # if rate exceeded
          end # begin / rescue
        end # while true
      end
      if child
        child = child + "Stack" unless child.end_with?("Stack")
        if outputs[child]
          childstack = outputs[child].split('/')[1]
          if @outputs[childstack]
            outputs = @outputs[childstack]
          else
            outputs = getoutputs(childstack)
          end
        else
          {}
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

  # Classes for processing yaml templates into AWS JSON templates
  # Convenience class for creating an AWS Outputs hash
  class Output
    attr_reader :output

    def initialize(desc, ref, lookup="Ref")
      @output = { "Description" => desc, "Value" => { "#{lookup}" => ref } }
    end
  end

  class CFTemplate
    attr_reader :name, :outputs, :param_includes

    def initialize(cloudcfg, stack, stack_config, cfg_name, parent = nil)
      @cloudcfg = cloudcfg
      if parent
        @parent = parent
      else
        @parent = self
      end
      raw = File::read(directory + "/" + @name.downcase() + ".yaml")
      raw = @cloudcfg.expand_strings(raw)
      puts "Loading #{@name}"
      @cfg = YAML::load(raw)
      @cloudcfg.resolve_vars({ "child" => @cfg }, "child")
      @res = @cfg["Resources"]
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
      resource["Properties"][tagkey] = cfgtags.cfntags()
    end

    # Returns an Array of string CIDRs, even if it's only 1 long
    def resolve_cidr(ref)
      clists = @cloudcfg["CIDRLists"]
      if @cloudcfg["SubnetTypes"]
        if @cloudcfg["SubnetTypes"][@parent.templatename][ref] != nil
          return [ @cloudcfg["SubnetTypes"][@parent.templatename][ref].cidr ]
        end
      end
      if clists[ref] != nil
        if clists[ref].class == Array
          return clists[ref]
        else
          return [ clists[ref] ]
        end
      else
        raise "Bad configuration item: \"#{ref}\" from #{self.name} not defined in \"CIDRLists\" section of cloudconfig.yaml"
      end
    end

    # Only called by a parent
    def process()
      if @param_includes
        @cfg["Parameters"] ||= {}
        params = @cfg["Parameters"]
        @param_includes.each() do |childname|
          other = @parent.find_child(childname)
          other.outputs().each_key() do |output|
            if params[output]
              STDERR.puts "WARNING: Duplicate input parameter (resource name) while processing includes for #{@name}: #{output}" if params[output]
            else
              params[output] = {"Type" => "String"}
            end
          end
        end
      end
      reskeys = @res.keys()
      reskeys.each do |reskey|
        @res[reskey]["Properties"] ||= {}
        case @res[reskey]["Type"]
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
        # Just tag these
        when "AWS::EC2::InternetGateway", "AWS::EC2::NetworkAcl", "AWS::EC2::Instance", "AWS::EC2::Volume", "AWS::EC2::VPC", "AWS::S3::Bucket"
          update_tags(@res[reskey], reskey)
        when "AWS::EC2::RouteTable"
          update_tags(@res[reskey], reskey)
          @outputs["#{reskey}"] = Output.new("Route Table Id for #{reskey}", reskey).output
        when "AWS::SDB::Domain"
          @outputs["#{reskey}Domain"] = Output.new("SDB Domain Name for #{reskey}", reskey).output
        when "AWS::IAM::InstanceProfile"
          @outputs["#{reskey}"] = Output.new("ARN for Instance Profile #{reskey}", [ reskey, "Arn" ], "Fn::GetAtt").output
        when "AWS::IAM::Role"
          @outputs["#{reskey}"] = Output.new("ARN for Role #{reskey}", [ reskey, "Arn" ], "Fn::GetAtt").output
        when "AWS::Route53::HostedZone"
          update_tags(@res[reskey],nil,"HostedZoneTags")
          @outputs["#{reskey}Id"] = Output.new("Hosted Zone Id for #{reskey}", reskey).output
        when "AWS::RDS::DBInstance"
          update_tags(@res[reskey], reskey)
          @outputs["#{reskey}"] = Output.new("Instance Identifier for #{reskey}", reskey).output
          @outputs["#{reskey}Addr"] = Output.new("Endpoint address for #{reskey}", [ reskey, "Endpoint.Address" ], "Fn::GetAtt").output
          @outputs["#{reskey}Port"] = Output.new("TCP port for #{reskey}", [ reskey, "Endpoint.Port" ], "Fn::GetAtt").output
        when "AWS::RDS::DBSubnetGroup"
          update_tags(@res[reskey], reskey)
          ref = @res[reskey]["Properties"]["SubnetIds"]
          if ref && ref[0] == '$'
            cfgref = ref[2..-1]
            if @st[cfgref] == nil
              raise "No configured subnet type for \"#{cfgref}\""
            end
            subrefs = []
            @res[reskey]["Properties"]["SubnetIds"] = subrefs
            @az.each_index do |i|
              subrefs << { "Ref" => cfgref + @az[i].upcase() }
            end
          end
          @outputs[reskey] = Output.new("#{reskey} database subnet group", reskey).output
        when "AWS::EC2::Subnet"
          ref = @res[reskey]["Properties"]["CidrBlock"]
          if ref && ref[0] == '$'
            cfgref = ref[2..-1]
            if @st[cfgref] == nil
              raise "No configured subnet type for \"#{cfgref}\""
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
        end # case
      end
    end
  end

  class MainTemplate < CFTemplate
    attr_reader :children, :templatename

    def initialize(cfg, stack)
      stack_config = cfg.load_stack_config(stack)
      @children = []
      @directory = "cfn/#{stack}"
      raise "Stack directory not found: cfn/#{stack}" unless File::stat(directory).directory?
      super(cfg, stack, stack_config, "MainTemplate")
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

end
