module RAWSTools
	RDS_Default_Template = <<EOF
  # db_name: "String" # We don't create a default database
  db_instance_identifier: ${@dbname} # required
  allocated_storage: ${@datasize|10}
  db_instance_class: ${@type|db.t2.micro} # available types vary by engine, probably needs override
  engine: (requires override)
  master_username: "root"
  master_user_password: ${@rootpassword}
  vpc_security_group_ids:
  - (requires override)
  db_subnet_group_name: (requires override)
  backup_retention_period: 2
  auto_minor_version_upgrade: true
  publicly_accessible: false
  storage_type: ${@storage_type|gp2}
  copy_tags_to_snapshot: true
  # monitoring_interval: 1
  # monitoring_role_arn: (requires override)
EOF
	class RDS
		attr_reader :client, :resource

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::RDS::Client.new(region: @mgr["Region"])
			@resource = Aws::RDS::Resource.new(client: @client)
		end

		def dump_template()
			puts <<EOF
---
api_template:
#{RDS_Default_Template}
EOF
		end

		# Set dbname parameter and check for existence of
		# the db instance
		def resolve_db_instance(must_exist=true)
			@mgr.normalize_name_parameters()
			name = @mgr.getparam("name")
			dbname = name.gsub(".","-")
			@mgr.setparam("dbname", dbname)
			dbi = @resource.db_instance(dbname)
			begin
				dbi.db_instance_arn
			rescue
				raise "No db instance found named #{dbname}" if must_exist
				return nil
			end
			return dbi
		end

		def list_db_instances()
			dbinstances = []
			@resource.db_instances().each do |i|
				if get_tag(i, "Domain") == @mgr["DNSDomain"]
					dbinstances << i
				end
			end
			return dbinstances
		end

		def get_tag(dbi, tagname)
			tags = @client.list_tags_for_resource({ resource_name: dbi.db_instance_arn() }).tag_list
			tags.each() do |tag|
				return tag.value if tag.key == tagname
			end
		end

		def list_snapshots()
			# TODO: implement
		end

		def create_snapshot(wait=false)
			# TODO: implement
		end

		def create_db_instance(template, wait=false)
			@mgr.normalize_name_parameters()
			name = @mgr.getparam("name")
			raise "Database instance #{name} already exists" if resolve_db_instance(false)
			dbname = @mgr.getparam("dbname")
			templatefile = nil
			if template.end_with?(".yaml")
				templatefile = template
			else
				templatefile = "rds/#{template}.yaml"
			end
			raw = File::read(templatefile)

			raw = @mgr.expand_strings(raw)
			template = YAML::load(raw)
			@mgr.resolve_vars( { "child" => template }, "child" )
			@mgr.symbol_keys(template)

			# Load the default template
			apibase = @mgr.expand_strings(RDS_Default_Template)
			dbspec = YAML::load(apibase)
			@mgr.resolve_vars( { "child" => dbspec }, "child" )
			@mgr.symbol_keys(dbspec)

			dbspec = dbspec.merge(template[:api_template])
			tags = dbspec[:tags]
			cfgtags = @mgr.tags()
			cfgtags["Name"] = name
			cfgtags["Domain"] = @mgr["DNSDomain"]
			cfgtags.add(tags) if tags
			dbspec[:tags] = cfgtags.ltags()

#			puts "Options hash:\n#{dbspec}"
			dbinstance = @resource.create_db_instance(dbspec)
			yield "Created db instance #{dbname} (id: #{dbinstance.id()}), waiting for it to become available"
			@client.wait_until(:db_instance_available, db_instance_identifier: dbname)
			yield "#{dbname} is online"

			# Get updated dbinstance with an endpoint
			dbinstance = resolve_db_instance()
			update_dns(wait, dbinstance) { |s| yield s }

			return dbinstance
		end

		def delete_db_instance(wait=true, deletestorage=false)
			# TODO: implement
		end

		def update_dns(wait=false, dbinstance=nil)
			@mgr.normalize_name_parameters()
			dbinstance = resolve_db_instance(true) unless dbinstance

			name, nodns = @mgr.getparams("name", "nodns")
			unless nodns
				cfqdn = @mgr.getparam("fqdn")
				fqdn = dbinstance.endpoint.address + "."
				puts "fqdn is #{fqdn}"
				@mgr.setparam("fqdn", fqdn)
				@mgr.setparam("cfqdn", cfqdn)

				# NOTE: rds instances should only be available
				# from the VPC and don't get public DNS
				privzone = @mgr["PrivateDNSId"]

				change_ids = []
				if privzone
					@mgr.setparam("zone_id", privzone)
					yield "Adding private DNS CNAME record #{name} -> #{cfqdn}"
					change_ids << @mgr.route53.change_records("cname")
				end
				return unless wait
				yield "Waiting for zones to synchronize..."
				change_ids.each() { |id| @mgr.route53.wait_sync(id) }
				yield "Synchronized"
			else
				yield "Not updating DNS for #{name}"
			end
		end
	end
end
