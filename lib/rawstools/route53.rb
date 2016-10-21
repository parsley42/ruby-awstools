module RAWSTools
	class Route53
		attr_reader :client

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::Route53::Client.new( region: @mgr["Region"] )
		end

		def lookup(zone, fqdn = nil)
			@mgr.normalize_name_parameters()
			fqdn = @mgr.getparam("fqdn") unless fqdn
			raise "No fqdn parameter or function argument; missing a call to normalize_name_parameters?" unless fqdn
			lookup = {
				hosted_zone_id: zone,
				start_record_name: fqdn,
				max_items: 1,
			}
			#puts "Looking up: #{lookup}"
			records = @client.list_resource_record_sets(lookup)
			values = []
			return values unless records.resource_record_sets.size() == 1
			return values unless records.resource_record_sets[0].name == fqdn
			records.resource_record_sets[0].resource_records.each do |record|
				values << record.value
			end
			return values
		end

		def delete(zone, fqdn = nil)
			@mgr.normalize_name_parameters()
			fqdn = @mgr.getparam("fqdn") unless fqdn
			raise "fqdn parameter not set; missing a call to normalize_name_parameters?" unless fqdn
			lookup = {
				hosted_zone_id: zone,
				start_record_name: fqdn,
				max_items: 1,
			}
			records = @client.list_resource_record_sets(lookup)
			record = records.resource_record_sets[0]
			return unless record.name == fqdn
			dset = {
				hosted_zone_id: zone,
				change_batch: {
					changes: [
						{
							action: "DELETE",
							resource_record_set: {
								name: fqdn,
								type: record.type,
								ttl: record.ttl,
								resource_records: record.resource_records
							}
						}
					]
				}
			}
			puts "Sending: #{dset}"
			resp = @client.change_resource_record_sets(dset)
			return resp
		end

		def change_records(template)
			@mgr.normalize_name_parameters()
			templatefile = nil
			if File::exist?("route53/#{template}.json")
				templatefile = "route53/#{template}.json"
			else
				templatefile = "#{@mgr.installdir}/templates/route53/#{template}.yaml"
			end
			raw = File::read(templatefile)
			raw = @mgr.expand_strings(raw)
			set = YAML::load(raw)

			@mgr.resolve_vars( { "child" => set }, "child" )
			@mgr.symbol_keys(set)

			resp = @client.change_resource_record_sets(set)
			return resp
		end

		def wait_sync(change)
			@client.wait_until(:resource_record_sets_changed, id: change.change_info.id )
		end
	end
end
