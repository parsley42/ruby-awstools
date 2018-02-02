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

    def initialize(cloudmgr, stack, sourcestack, stack_config, filename)
      @mgr = cloudmgr
      @stackconfig = stack_config
      @stackdef = stack # local load dir
      @sourcestack = sourcestack # searchpath load dir
      @stackname = stack_config["StackName"]
      @directory = "cfn/#{stack}/#{@stackname}"
      @client = @mgr.cfn.client
      @filename = filename
      @noupload = stack_config["DisableUpload"] # note nil is also false
      @s3key = "#{@stackname}/#{@filename}"
      prefix = @mgr["Prefix"]
      if prefix
        @s3key = "#{prefix}/" + @s3key
      end

      # Load the first CloudFormation stack definition found, looking in the local
      # directory first, then reverse order of the SearchPath, and finally the
      # library templates. When found:
      # - If it's yaml, replace !Ref with BangRef, !GetAtt with BangGetAtt, etc.
      found = false
      @mgr.log(:debug, "Looking for ./cfn/#{@stackdef}/#{@filename}")
      if File::exist?("./cfn/#{@stackdef}/#{@filename}")
        @mgr.log(:info, "Loading CloudFormation stack template ./cfn/#{@stackdef}/#{@filename}")
        @raw = File::read("./cfn/#{@stackdef}/#{@filename}")
        found = true
      end
      unless found
        search_dirs = ["#{@mgr.installdir}/templates"]
        if @mgr["SearchPath"]
          search_dirs += @mgr["SearchPath"]
        end
        search_dirs.reverse!
        search_dirs.each do |dir|
          @mgr.log(:debug, "Looking for #{dir}/cfn/#{@sourcestack}/#{@filename}")
          if File::exist?("#{dir}/cfn/#{@sourcestack}/#{@filename}")
            @mgr.log(:info, "Loading CloudFormation stack template #{dir}/cfn/#{@sourcestack}/#{@filename}")
            @raw = File::read("#{dir}/cfn/#{@sourcestack}/#{@filename}")
            found = true
            break
          end
        end
      end
      unless found
        raise "Couldn't find #{@filename} for stack definition: #{@stackdef}, source stack: #{@sourcestack}"
      end
    end

    # Validate the template
    def validate()
      @mgr.log(:debug,"Validating #{@stackdef}:#{@filename}")
      resp = @client.validate_template({ template_body: @raw })
      @mgr.log(:info,"Validated #{@stackdef}:#{@filename}: #{resp.description}")
      if resp.capabilities.length > 0
        @mgr.log(:info, "Capabilities: #{resp.capabilities.join(",")}")
        @mgr.log(:info, "Reason: #{resp.capabilities_reason}")
      end
      return resp.capabilities
    end

    # Upload the template to the proper S3 location
    def upload()
      obj = @mgr.s3res.bucket(@mgr["Bucket"]).object(@s3key)
      @mgr.log(:info,"Uploading cloudformation stack template #{@stackdef}:#{@filename} to s3://#{@mgr["Bucket"]}/#{@s3key}")
      template = @mgr.load_template("s3", "cfnput")
      @mgr.symbol_keys(template)
      @mgr.resolve_vars(template, :api_template)
      params = template[:api_template]
      params[:body] = @raw
      obj.put(params)
    end

    # Write the template out to a file
    def write()
      f = File.open("#{@directory}/#{@filename}", "w")
      f.write(@raw)
      f.close()
    end

  end

  class MainTemplate < CFTemplate
    attr_reader :children, :templatename

    # NOTE: only the MainTemplate has @children and @stackconfig
    def initialize(mgr, stack)
      @children = []
      @disable_rollback, @generate_only = mgr.getparams("disable_rollback", "generate_only")
      @disable_rollback = false unless @disable_rollback
      sourcestack = stack
      if File::exist?("cfn/#{stack}/stackconfig.yaml")
        raw = File::read("cfn/#{stack}/stackconfig.yaml")
        c = YAML::load(raw)
        if c && c["SourceStack"]
          # NOTE: the value for SourceStack Currently doesn't get expanded.
          sourcestack = c["SourceStack"]
          mgr.log(:debug, "Set SourceStack to #{sourcestack}")
        end
      end
      # Load CloudFormation stackconfig.yaml, first from SearchPath, then from
      # stack path. Raise exception if no stackconfig.yaml found.
      search_dirs = ["#{mgr.installdir}/templates"]
      if mgr["SearchPath"]
        search_dirs += mgr["SearchPath"]
      end
      stack_config = {}
      found = false
      search_dirs.each do |dir|
        mgr.log(:debug, "Looking for #{dir}/cfn/#{sourcestack}/stackconfig.yaml")
        if File::exist?("#{dir}/cfn/#{sourcestack}/stackconfig.yaml")
          mgr.log(:info, "Loading stack configuration from #{dir}/cfn/#{sourcestack}/stackconfig.yaml")
          raw = File::read("#{dir}/cfn/#{sourcestack}/stackconfig.yaml")
          mgr.merge_templates(YAML::load(raw), stack_config)
          found = true
        end
      end
      # Finally merge w/ repository version, if present.
      mgr.log(:debug, "Looking for ./cfn/#{stack}/stackconfig.yaml")
      if File::exist?("./cfn/#{stack}/stackconfig.yaml")
        mgr.log(:info, "Loading stack configuration from ./cfn/#{stack}/stackconfig.yaml")
        raw = File::read("./cfn/#{stack}/stackconfig.yaml")
        mgr.merge_templates(YAML::load(raw), stack_config)
        found = true
      end
      raise "Unable to locate stackconfig.yaml for stack: #{stack}, source stack: #{sourcestack}" unless found
      stack_config["StackName"] = stack unless stack_config["StackName"]
      if stack_config["S3URL"]
        s3urlprefix = stack_config["S3URL"]
      else
        s3urlprefix = "https://s3.amazonaws.com"
      end
      s3urlprefix = "#{s3urlprefix}/#{mgr["Bucket"]}/"
      prefix = mgr["Prefix"]
      if prefix
        s3urlprefix += "#{prefix}/"
      end
      s3urlprefix += "#{stack_config["StackName"]}"
      mgr.log(:debug, "Setting generated parameter \"s3urlprefix\" to: #{s3urlprefix}")
      mgr.setparam("s3urlprefix", s3urlprefix)
      resparent = { "stackconfig" => stack_config }
      mgr.resolve_vars(resparent, "stackconfig")
      FileUtils::mkdir_p("cfn/#{stack}/#{stack_config["StackName"]}")
      super(mgr, stack, sourcestack, stack_config, stack_config["MainTemplate"])
      if stack_config["ChildStacks"]
        stack_config["ChildStacks"].each do |filename|
          child = CFTemplate.new(@mgr, @stackdef, @sourcestack, @stackconfig, filename)
          @children.push(child)
        end
      end
    end

    def write_all()
      write()
      @children.each() { |child| child.write() }
      f = File.open("#{@directory}/stackconfig.yaml", "w")
      f.write(YAML::dump(@stackconfig, { line_width: -1, indentation: 4 }))
      f.close()
    end

    def upload_all_conditional()
      upload() unless @noupload
      @children.each() { |child| child.upload() }
    end

    def get_stack_parameters()
      return nil unless @stackconfig["Parameters"]
      parameters = []
      @mgr.resolve_vars(@stackconfig, "Parameters")
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
      upload_all_conditional()
      required_capabilities = get_stack_required_capabilities()
      tags = @mgr.tags.apitags()
      params = {
        stack_name: @mgr.stack_family + @stackname,
        tags: tags,
        capabilities: required_capabilities,
        disable_rollback: @disable_rollback,
        template_body: @raw,
      }
      parameters = get_stack_parameters()
      write_all()
      if @generate_only
        @mgr.log(:info, "Exiting without action on user request")
        return "generate only"
      end
      if parameters
        params[:parameters] = parameters
      end
      if op == :create
        stackout = @client.create_stack(params)
        @mgr.log(:info, "Created stack #{@stackdef}:#{@stackname}: #{stackout.stack_id}")
      else
        params.delete(:disable_rollback)
        stackout = @client.update_stack(params)
        @mgr.log(:info, "Issued update for stack #{@stackdef}:#{@stackname}: #{stackout.stack_id}")
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
      @mgr.log(:warn, "Deleting stack #{@stackdef}:#{@stackname}")
      @client.delete_stack({ stack_name: @mgr.stack_family + @stackname })
    end

    def Validate()
      validate()
      @children.each() { |child| child.validate() }
    end

  end

end
