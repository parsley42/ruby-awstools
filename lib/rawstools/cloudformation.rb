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
end
