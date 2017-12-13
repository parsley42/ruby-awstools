module RAWSTools

  Loc_Regex = /([\w]*)#([FL0-9a-j?])([\w]*)/
  Split_Regex = /(?<!:):{1}(?!:)/

  Tag_Resources = [ "AWS::EC2::InternetGateway", "AWS::EC2::NetworkAcl",
    "AWS::EC2::Instance", "AWS::EC2::Volume", "AWS::EC2::VPC",
    "AWS::S3::Bucket", "AWS::EC2::RouteTable", "AWS::RDS::DBInstance",
    "AWS::RDS::DBSubnetGroup", "AWS::EC2::SecurityGroup",
    "AWS::EC2::Subnet", "AWS::CloudFormation::Stack"
  ]

  YAML_ShortFuncs = [ "Ref", "GetAtt", "Base64", "FindInMap", "Equals",
    "If", "And", "Or", "Not", "Sub" ]

  class CloudFormation
    attr_reader :client, :resource

    def initialize(cloudmgr)
      @mgr = cloudmgr
      @client = Aws::CloudFormation::Client.new( @mgr.client_opts )
      @resource = Aws::CloudFormation::Resource.new( client: @client )
      @resources = {}
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

    # Recursively walk down CloudFormation stacks and return the resources
    # of the last stack in a parent(:child(:child)...) resourcesspec.
    # Results are cached in the @resources[stackname] in-memory hash.
    def getresources(resourcesspec)
      components = resourcesspec.split(Split_Regex)
      parent = components.shift()
      childspec = components.join(':')
      prefix = @mgr.stack_family
      if prefix
        parent = prefix + parent unless parent.start_with?(prefix)
      end
      if @resources[parent]
        resources = @resources[parent]
      else
        stack = @resource.stack(parent)
        resources = {}
        @resources[parent] = resources
        tries = 0
        while true
          begin
            if stack.exists?()
              stack.resource_summaries().each() do |r|
                resources[r.data.logical_resource_id] = "#{r.data.physical_resource_id}=#{r.data.resource_type}"
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
      if childspec == ""
        return resources
      end
      children = resources.keys()
      components = childspec.split(Split_Regex)
      parentspec = components.shift()
      childspec = components.join(':')
      stackresource = nil
      if children.include?("#{parentspec}")
        stackresource = parentspec
      elsif children.include?("#{parentspec}Stack")
        stackresource = "#{parentspec}Stack"
      elsif children.include?("#{parentspec}Template")
        stackresource = "#{parentspec}Template"
      end
      return {} unless stackresource
      # Example stack resource:
      # arn:aws:cloudformation:us-east-1:123456789012:stack/vpc-NetworkAclsStack-1S9R8KNR0ZGPM/1ac14690-cdce-11e6-9688-50fae97e0835
      value, type = resources[stackresource].split('=')
      raise "Wrong type for #{stackresource} in #{resourcespec}, required: AWS::CloudFormation::Stack, actual: #{type}" unless type == "AWS::CloudFormation::Stack"
      parent = value.split('/')[1]
      if childspec == ""
        return getresources(parent)
      else
        return getresources("#{parent}:#{childspec}")
      end
    end

    # Return the value of a CloudFormation resource. When the resource name
    # contains /#[FL0-9?a-j]/, return one of multiple matching resources.
    # (F)irst, (L)ast, Indexed(0-9), Random(?), or given availability zone.
    def getresource(resourcespec)
      terms = resourcespec.split(Split_Regex)
      raise "Invalid resource specifier, no separators in #{resourcespec}" unless terms.count > 1
      resource = terms.pop()
      res_type = nil
      property = nil
      if resource =~ /=/
        resource, res_type = resource.split('=')
      end
      if resource =~ /\./
        resource, property = resource.split('.')
      end
      stack = terms.join(':')
      resources = getresources(stack)
      match = resource.match(Loc_Regex)
      if match
        if res_type
          raise "Location specifier given for non-subnet resource type: #{res_type}" unless res_type == "AWS::EC2::Subnet"
        end
        matching = []
        subnets = []
        re = Regexp.new("#{match[1]}.#{match[3]}")
        loc = match[2]
        resources.keys.each do |key|
          if key.match(re)
            resource, type = resources[key].split('=')
            next unless type == "AWS::EC2::Subnet"
            matching.push(key)
            subnets.push(resource)
          end
        end
        matching.sort!()
        case loc
        when "F"
          return resources[matching[0]].split('=')[0]
        when "L"
          return resources[matching[-1]].split('=')[0]
        when "?"
          return resources[matching.sample()].split('=')[0]
        when /[a-j]/
          sn = @mgr.ec2.client.describe_subnets({ subnet_ids: subnets })
          sn.subnets.each do |subnet|
            if subnet.availability_zone.end_with?(loc)
              return subnet.subnet_id
            end
          end
          raise "No subnet found with availability zone #{loc} for #{resource}"
        else
          i=loc.to_i()
          raise "Invalid location index #{i} for #{resource}" unless matching[i]
          return resources[matching[i]].split('=')[0]
        end
      else
        raise "CloudFormation resource not found: #{resourcespec}" unless resources[resource]
        value, type = resources[resource].split('=')
        if res_type
          raise "Resource type mismatch for #{resourcespec}, type for #{resource} is #{type}" unless type == res_type
        end
        if property
          return @mgr.get_resource_property(type, value, property)
        end
        return value
      end
    end
  end

  # Classes for processing yaml/json templates

  class CFTemplate
    attr_reader :name, :resources, :s3url, :noupload

    def initialize(cloudcfg, stack, sourcestack, stack_config, cfg_name, parent)
      @cloudcfg = cloudcfg
      @parent = parent
      @stackconfig = stack_config
      raise "stackconfig.yaml has no stanza for #{cfg_name}" unless stack_config[cfg_name]
      @directory = "cfn/#{stack}"
      @stack = stack
      @sourcestack = sourcestack
      @name = cfg_name
      @cloudcfg.resolve_vars(stack_config, cfg_name)
      @stackname = stack_config["MainTemplate"]["StackName"]
      @client = @cloudcfg.cfn.client
      scfg = stack_config[cfg_name]
      @filename = scfg["File"]
      @format = scfg["Format"]
      @noupload = scfg["DisableUpload"] # note nil is also false
      @autoutputs = scfg["AutoOutputs"] # note nil is also false
      if stack_config["MainTemplate"]["S3URLPrefix"]
        @s3urlprefix = stack_config["MainTemplate"]["S3URLPrefix"]
      else
        @s3urlprefix = "https://s3.amazonaws.com"
      end
      @s3url = "#{@s3urlprefix}/#{cloudcfg["Bucket"]}/"
      @s3key = "#{@stackname}/#{@filename}"
      prefix = @cloudcfg["Prefix"]
      if prefix
        @s3url += "#{prefix}/"
        @s3key = "#{prefix}/" + @s3key
      end
      @s3url += "#{@stackname}/#{@filename}"
      # Load the first CloudFormation stack definition found, looking in the local
      # directory first, then reverse order of the SearchPath, and finally the
      # library templates. When found:
      # - If it's yaml, replace !Ref with BangRef, !GetAtt with BangGetAtt, etc.
      found = false
      @cloudcfg.log(:debug, "Looking for ./cfn/#{@stack}/#{@filename}")
      if File::exist?("./cfn/#{@stack}/#{@filename}")
        @cloudcfg.log(:debug, "=> Loading ./cfn/#{@stack}/#{@filename}")
        @raw = File::read("./cfn/#{@stack}/#{@filename}")
        found = true
      end
      unless found
        search_dirs = ["#{@cloudcfg.installdir}/templates"]
        if @cloudcfg["SearchPath"]
          search_dirs += @cloudcfg["SearchPath"]
        end
        search_dirs.reverse!
        search_dirs.each do |dir|
          @cloudcfg.log(:debug, "Looking for #{dir}/cfn/#{@sourcestack}/#{@filename}")
          if File::exist?("#{dir}/cfn/#{@sourcestack}/#{@filename}")
            @cloudcfg.log(:debug, "=> Loading #{dir}/cfn/#{@sourcestack}/#{@filename}")
            @raw = File::read("#{dir}/cfn/#{@sourcestack}/#{@filename}")
            found = true
            break
          end
        end
      end
      unless found
        raise "Couldn't find #{@filename} for stack: #{@stack}, source stack: #{@sourcestack}"
      end
      # AWS CloudFormation yaml needs pre-processing to be read in to a data
      # structure.
      if @format.casecmp("yaml") == 0
        write_raw("-0-orig")
        # Note: render() needs to undo this by replacing <LB>, <RB>, and <CMA>
        # with '[', ']',  and ','
        bfunc_re = /!(Equals|If|And|Or|Not|GetAtt)(\s+\[([^\[\]]+)\])/
        while @raw.match(bfunc_re)
          @raw = @raw.gsub(bfunc_re) do
            func = $1
            brack = $2.gsub('[', "<LB>")
            brack = brack.gsub(']', "<RB>")
            brack = brack.gsub(',', "<CMA>")
            "!#{func}#{brack}"
          end
        end
        write_raw("-1-bfunc")
        # Preserve flow mappings, replace '{', '}' with '<LBC>', '<RBC>'
        flow_re = /(\s+-\s+){([^{}]+)}(\s*)/
        @raw = @raw.gsub(flow_re) do
          rep = "#{$1}<LBC>#{$2}<RBC>#{$3}"
          rep.gsub(':', "<CLN>")
        end
        write_raw("-2-braces")
        # Replace "!<shortfunc>" with "Bang<shortfunc>" for yaml; render()
        # needs to undo this.
        YAML_ShortFuncs.each do |sfunc|
          @raw = @raw.gsub(/!#{sfunc}/, "Bang#{sfunc}")
        end
        write_raw("-3-sfunc")
        # Note: render() needs to remove the trailing ':'
        oneline_re = /^(\s+)(\w+:\s+)(Bang\w+)(\s+\|\s*)?$/
        @raw = @raw.gsub(oneline_re) do
          indent = ' ' * ($1.length() + 2)
          "#{$1}#{$2}\n#{indent}#{$3}:#{$4}"
        end
        # For troubleshooting, write the file out before trying to load it
        write_raw("-4-oneline")
        @template = YAML::load(@raw)
      else
        @template = JSON::load(@raw)
      end
      # NOTE: best practices would be NOT using rawstools vars, but setting
      # all vars as stack parameters in the stackconfig.yaml
      @cloudcfg.resolve_vars({ "child" => @template }, "child")
      @res = @template["Resources"]
      @template["Outputs"] ||= {}
      @outputs = @template["Outputs"]
      process_template()
    end

    # Render a template to text
    def render()
      if @format.casecmp("yaml") == 0
        @raw = YAML::dump(@template, { line_width: -1, indentation: 4 })
        write_raw("-5-fresh")
        @raw = @raw.gsub("<LB>", '[')
        @raw = @raw.gsub("<RB>", ']')
        # Restore the braces for a flow mapping
        @raw = @raw.gsub(/"?<LBC>/, '{')
        @raw = @raw.gsub(/<RBC>"?/, '}')
        @raw = @raw.gsub("<CMA>", ',')
        @raw = @raw.gsub("<CLN>", ':')
        write_raw("-6-brack")
        oneline_re = /^(\s+Bang\w+):(\s+\|\s*)?$/
        @raw = @raw.gsub(oneline_re) do
          "#{$1}#{$2}"
        end
        write_raw("-7-oneline")
        YAML_ShortFuncs.each do |sfunc|
          @raw = @raw.gsub(/Bang#{sfunc}/, "!#{sfunc}")
        end
        write_raw("-8-rsfunc")
        return @raw
      else
        return JSON::pretty_generate(@template)
      end
    end

    # Validate the template
    def validate()
      @cloudcfg.log(:debug,"Validating #{@stack}:#{@name}")
      resp = @client.validate_template({ template_body: render() })
      @cloudcfg.log(:info,"Validated #{@stack}:#{@name}: #{resp.description}")
      if resp.capabilities.length > 0
        @cloudcfg.log(:info, "Capabilities: #{resp.capabilities.join(",")}")
        @cloudcfg.log(:info, "Reason: #{resp.capabilities_reason}")
      end
      return resp.capabilities
    end

    # Upload the template to the proper S3 location
    def upload()
      obj = @cloudcfg.s3res.bucket(@cloudcfg["Bucket"]).object(@s3key)
      @cloudcfg.log(:info,"Uploading cloudformation stack template #{@stack}:#{@name} to #{@s3url}")
      template = @cloudcfg.load_template("s3", "cfnput")
      @cloudcfg.symbol_keys(template)
      @cloudcfg.resolve_vars(template, :api_template)
      params = template[:api_template]
      params[:body] = render()
      obj.put(params)
    end

    # Write the template out to a file
    def write()
      f = File.open("#{@directory}/output/#{@filename}", "w")
      f.write(render())
      f.close()
    end

    # Write the template out to a file
    def write_raw(suffix)
      # To debug yaml loading and rendering, comment out the return
      # to dump the proceessed text at every stage.
      return
      f = File.open("#{@directory}/output/#{@filename}#{suffix}", "w")
      f.write(@raw)
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

    # Helper method for generating CloudFormation outputs
    def gen_output(desc, ref, lookup="Ref")
      @cloudcfg.log(:debug, "Adding output for #{@name}: #{lookup} => #{ref}")
      return { "Description" => desc, "Value" => { "#{lookup}" => ref } }
    end

    # process a template, including:
    # - Expand CIDRList references
    # - Handle child templates and add outputs for cfn lookups
    # - Add automatic outputs if @autoutputs is true
    # - Apply common tags to all resource types in the Tag_Resources array
    def process_template()
      reskeys = @res.keys()
      reskeys.each do |reskey|
        @cloudcfg.log(:debug, "Processing resource #{reskey}, type #{@res[reskey]["Type"]} in #{@filename}")
        @res[reskey]["Properties"] = {} unless @res[reskey]["Properties"]
        if Tag_Resources.include?(@res[reskey]["Type"])
          update_tags(@res[reskey], reskey)
        end
        case @res[reskey]["Type"]
        when "AWS::CloudFormation::Stack"
          # NOTE: There's really no reason for this ... ?
          # if @name != "MainTemplate"
          #   raise "Child stacks must be defined in the \"MainTemplate\" file"
          # end
          unless @stackconfig[reskey]
            @cloudcfg.log(:debug, "Deleting orphan child stack resource #{reskey} (not listed in stackconfig.yaml)")
            @res.delete(reskey)
            next
          end
          # Every child needs an output to enable parent:child:output lookups
          @outputs[reskey] = gen_output("#{reskey} child stack", reskey) if @autoutputs
          child = CFTemplate.new(@cloudcfg, @stack, @sourcestack, @stackconfig, reskey, @parent)
          @parent.children.push(child)
          @res[reskey]["Properties"]["TemplateURL"] = child.s3url
          @cloudcfg.log(:debug, "Found child template #{child.name}, url: #{child.s3url}")
        when "AWS::EC2::RouteTable"
          @outputs["#{reskey}"] = gen_output("Route Table Id for #{reskey}", reskey) if @autoutputs
        when "AWS::SDB::Domain"
          @outputs["#{reskey}Domain"] = gen_output("SDB Domain Name for #{reskey}", reskey) if @autoutputs
        when "AWS::IAM::InstanceProfile"
          @outputs["#{reskey}"] = gen_output("ARN for Instance Profile #{reskey}", [ reskey, "Arn" ], "Fn::GetAtt") if @autoutputs
        when "AWS::IAM::Role"
          @outputs["#{reskey}"] = gen_output("ARN for Role #{reskey}", [ reskey, "Arn" ], "Fn::GetAtt") if @autoutputs
        when "AWS::Route53::HostedZone"
          update_tags(@res[reskey],nil,"HostedZoneTags")
          @outputs["#{reskey}Id"] = gen_output("Hosted Zone Id for #{reskey}", reskey) if @autoutputs
        when "AWS::RDS::DBInstance"
          @outputs["#{reskey}"] = gen_output("Instance Identifier for #{reskey}", reskey) if @autoutputs
          @outputs["#{reskey}Addr"] = gen_output("Endpoint address for #{reskey}", [ reskey, "Endpoint.Address" ], "Fn::GetAtt") if @autoutputs
          @outputs["#{reskey}Port"] = gen_output("TCP port for #{reskey}", [ reskey, "Endpoint.Port" ], "Fn::GetAtt") if @autoutputs
        when "AWS::RDS::DBSubnetGroup"
          @outputs[reskey] = gen_output("#{reskey} database subnet group", reskey) if @autoutputs
        when "AWS::EC2::Subnet"
          @outputs[reskey] = gen_output("SubnetId of #{reskey} subnet", reskey) if @autoutputs
        when "AWS::EC2::SecurityGroup"
          @outputs[reskey] = gen_output("#{reskey} security group", reskey) if @autoutputs
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

    # NOTE: only the MainTemplate has @children and @stackconfig
    def initialize(cfg, stack)
      @children = []
      @disable_rollback, @generate_only = cfg.getparams("disable_rollback", "generate_only")
      @disable_rollback = false unless @disable_rollback
      sourcestack = stack
      if File::exist?("cfn/#{stack}/stackconfig.yaml")
        raw = File::read("cfn/#{stack}/stackconfig.yaml")
        c = YAML::load(raw)
        if c && c["SourceStack"]
          # NOTE: the value for SourceStack Currently doesn't get expanded.
          sourcestack = c["SourceStack"]
          cfg.log(:debug, "Set SourceStack to #{sourcestack}")
        end
      end
      FileUtils::mkdir_p("cfn/#{stack}/output")
      # Load CloudFormation stackconfig.yaml, first from SearchPath, then from
      # stack path. Raise exception if no stackconfig.yaml found.
      search_dirs = ["#{cfg.installdir}/templates"]
      if cfg["SearchPath"]
        search_dirs += cfg["SearchPath"]
      end
      stack_config = {}
      found = false
      search_dirs.each do |dir|
        cfg.log(:debug, "Looking for #{dir}/cfn/#{sourcestack}/stackconfig.yaml")
        if File::exist?("#{dir}/cfn/#{sourcestack}/stackconfig.yaml")
          cfg.log(:debug, "=> Loading #{dir}/cfn/#{sourcestack}/stackconfig.yaml")
          raw = File::read("#{dir}/cfn/#{sourcestack}/stackconfig.yaml")
          cfg.merge_templates(YAML::load(raw), stack_config)
          found = true
        end
      end
      # Finally merge w/ repository version, if present.
      cfg.log(:debug, "Looking for ./cfn/#{stack}/stackconfig.yaml")
      if File::exist?("./cfn/#{stack}/stackconfig.yaml")
        cfg.log(:debug, "=> Loading ./cfn/#{stack}/stackconfig.yaml")
        raw = File::read("./cfn/#{stack}/stackconfig.yaml")
        cfg.merge_templates(YAML::load(raw), stack_config)
        found = true
      end
      raise "Unable to locate stackconfig.yaml for stack: #{stack}, source stack: #{sourcestack}" unless found
      if stack_config["MainTemplate"]
        stack_config["MainTemplate"]["StackName"] = stack unless stack_config["MainTemplate"]["StackName"]
      else
        raise "MainTemplate definition not found for #{stack}"
      end
      super(cfg, stack, sourcestack, stack_config, "MainTemplate", self)
    end

    def write_all()
      write()
      @children.each() { |child| child.write() }
    end

    def upload_all_conditional()
      upload() unless @noupload
      @children.each() { |child| child.upload() unless child.noupload }
    end

    def get_stack_parameters()
      return nil unless @stackconfig["Parameters"]
      parameters = []
      @cloudcfg.resolve_vars(@stackconfig, "Parameters")
      @stackconfig["Parameters"].each_key() do |key|
        value = @stackconfig["Parameters"][key]
        parameters.push({ parameter_key: key, parameter_value: value})
      end
      return parameters
    end

    def get_stack_required_capabilities()
      stack_required_capabilities = validate()
      @children.each() do |child|
        stack_required_capabilities += child.validate()
      end
      stack_required_capabilities.uniq!()
      return stack_required_capabilities
    end

    # Create or Update a cloudformation stack
    def create_or_update(op)
      write_all()
      upload_all_conditional()
      required_capabilities = get_stack_required_capabilities()
      tags = @cloudcfg.tags.apitags()
      template = render()
      params = {
        stack_name: @cloudcfg.stack_family + @stackname,
        tags: tags,
        capabilities: required_capabilities,
        disable_rollback: @disable_rollback,
        template_body: template,
      }
      parameters = get_stack_parameters()
      if parameters
        params[:parameters] = parameters
      end
      if op == :create
        stackout = @client.create_stack(params)
        @cloudcfg.log(:info, "Created stack #{@stack}:#{@name}: #{stackout.stack_id}")
      else
        params.delete(:disable_rollback)
        stackout = @client.update_stack(params)
        @cloudcfg.log(:info, "Issued update for stack #{@stack}:#{@name}: #{stackout.stack_id}")
      end
      return stackout
    end

    def Create()
      return create_or_update(:create)
    end

    def Update()
      return create_or_update(:update)
    end

    def Delete()
      @cloudcfg.log(:warn, "Deleting stack #{@stack}:#{@name}")
      @client.delete_stack({ stack_name: @cloudcfg.stack_family + @stackname })
    end

    def Validate()
      validate()
      @children.each() { |child| child.validate() }
    end

  end

end
