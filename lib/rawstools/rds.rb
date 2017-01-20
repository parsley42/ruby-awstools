module RAWSTools
	RDS_Default_Template = <<EOF
  # db_name: "String" # We don't create a default database
  db_instance_identifier: ${@dbname} # required
  allocated_storage: ${@datasize|10}
  iops: ${@iops|0}
  db_instance_class: ${@type|db.t2.micro} # available types vary by engine, probably needs override
  engine: (requires override)
  master_username: "root"
  master_user_password: ${@rootpassword}
  vpc_security_group_ids:
  - (requires override)
  availability_zone: ${@availability_zone|none}
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
			if dbi.class == Aws::RDS::DBInstance
				arn = dbi.db_instance_arn()
			else
				arn = dbi.db_snapshot_arn()
			end
			tags = @client.list_tags_for_resource({ resource_name: arn }).tag_list
			tags.each() do |tag|
				return tag.value if tag.key == tagname
			end
		end

		def list_snapshots(name=nil)
			dbsnapshots = []
			params = {}
			if name
				@mgr.setparam("name", name)
				@mgr.normalize_name_parameters()
				name = @mgr.getparam("name")
				dbname = name.gsub(".","-")
				params[:db_instance_identifier] = dbname
			end
			@resource.db_snapshots(params).each do |s|
				if get_tag(s, "Domain") == @mgr["DNSDomain"]
					dbsnapshots << s
				end
			end
			return dbsnapshots
		end

		def create_snapshot(name, wait=false)
			@mgr.setparam("name", name)
			@mgr.normalize_name_parameters()
			name, dbname = @mgr.getparams("name", "dbname")

			dbinstance = resolve_db_instance()
			unless dbinstance
				yield "Unable to resolve db instance #{name}"
				return
			end
			snapname = "#{dbname}-#{@mgr.timestamp()}"
			yield "Creating snapshot #{snapname} for #{name}"
			dbinstance.create_snapshot({ db_snapshot_identifier: snapname })
		end

		def create_instance(name, rootpass, template, wait)
			@mgr.setparam("name", name)
			@mgr.setparam("rootpassword", rootpass)
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
			dbspec.delete(:availability_zone) unless @mgr.getparam("availability_zone")
			dbspec.delete(:iops) unless dbspec[:storage_type] == "io1"

			dbspec = dbspec.merge(template[:api_template])
			tags = dbspec[:tags]
			cfgtags = @mgr.tags()
			cfgtags["Name"] = name
			cfgtags["Domain"] = @mgr["DNSDomain"]
			cfgtags.add(tags) if tags
			dbspec[:tags] = cfgtags.ltags()

#			puts "Options hash:\n#{dbspec}"
			dbinstance = @resource.create_db_instance(dbspec)
			yield "#{@mgr.timestamp()} Created db instance #{dbname} (id: #{dbinstance.id()}), waiting for it to become available"
			@client.wait_until(:db_instance_available, db_instance_identifier: dbname)
			yield "#{@mgr.timestamp()} #{dbname} is online"

			# Get updated dbinstance with an endpoint
			dbinstance = resolve_db_instance()
			update_dns(nil, wait, dbinstance) { |s| yield s }

			return dbinstance
		end

		def delete_instance(name, wait=true, unsafe=false)
			@mgr.setparam("name", name)
			@mgr.normalize_name_parameters()
			name, dbname, fqdn = @mgr.getparams("name", "dbname", "fqdn")
			dbinstance = resolve_db_instance(true)

			if unsafe
				yield "#{@mgr.timestamp()} Permanently deleting #{name}"
				dbinstance.delete({ skip_final_snapshot: true })
			else
				snapname = "#{dbname}-#{@mgr.timestamp()}"
				yield "#{@mgr.timestamp()} Creating final snapshot #{snapname} and deleting #{name}"
				dbinstance.delete({
					skip_final_snapshot: false,
					final_db_snapshot_identifier: snapname
				})
			end

			if wait
				yield "#{@mgr.timestamp()} Waiting for db instance to finish deleting..."
				@client.wait_until(:db_instance_deleted, db_instance_identifier: dbname)
				yield "#{@mgr.timestamp()} Deleted"
			end

			yield "#{@mgr.timestamp()} Removing private DNS record #{fqdn}"
			privzone = @mgr["PrivateDNSId"]
			change_id = @mgr.route53.delete(privzone)
			return unless wait

			yield "#{@mgr.timestamp()} Waiting for zone to synchronize..."
			@mgr.route53.wait_sync(change_id)
			yield "#{@mgr.timestamp()} Synchronized"
		end

		def update_dns(name=nil, wait=false, dbinstance=nil)
			if name
				@mgr.setparam("name", name)
				@mgr.normalize_name_parameters()
			end
			dbinstance = resolve_db_instance(true) unless dbinstance

			name = @mgr.getparam("name")
			cfqdn = @mgr.getparam("fqdn")
			fqdn = dbinstance.endpoint.address + "."
			#puts "fqdn is #{fqdn}"
			@mgr.setparam("fqdn", fqdn)
			@mgr.setparam("cfqdn", cfqdn)

			# NOTE: rds instances should only be available
			# from the VPC and don't get public DNS
			privzone = @mgr["PrivateDNSId"]

			change_ids = []
			if privzone
				@mgr.setparam("zone_id", privzone)
				yield "#{@mgr.timestamp()} Adding private DNS CNAME record #{fqdn} -> #{cfqdn}"
				change_ids << @mgr.route53.change_records("cname")
			end
			return unless wait
			yield "#{@mgr.timestamp()} Waiting for zones to synchronize..."
			change_ids.each() { |id| @mgr.route53.wait_sync(id) }
			yield "#{@mgr.timestamp()} Synchronized"
		end
	end
end
