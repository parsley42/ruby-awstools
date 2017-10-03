module RAWSTools
	RDS_Default_Template = <<EOF
  # db_name: "String" # We don't create a default database
  db_instance_identifier: ${@dbname} # required
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

	RDS_Restore_Template = <<EOF
  db_instance_identifier: ${@dbname} # required
  db_instance_class: ${@type|db.t2.micro}
  availability_zone: ${availability_zone|none}
  publicly_accessible: false
  auto_minor_version_upgrade: true
  engine: (requires override)
  iops: ${@iops|0}
  storage_type: ${@storage_type|gp2}
  copy_tags_to_snapshot: true
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
		def resolve_instance(name=nil)
			if name
				@mgr.setparam("name", name)
				@mgr.normalize_name_parameters()
			end
			name, dbname = @mgr.getparams("name", "dbname")
			dbi = @resource.db_instance(dbname)
			begin
				# Innocuous call that will raise an exception if it doesn't exist
				dbi.db_instance_arn
			rescue
				return nil
			end
			return dbi
		end

		def resize_storage(name, size)
			if dbi = resolve_instance(name)
				return resize_instance_storage(dbi, size)
			end
			return false, "Instance #{name} not found"
		end

		def resize_instance_storage(instance, size)
			begin
				instance = instance.modify({
					apply_immediately: false,
					allocated_storage: size,
				})
			rescue => e
				return false, e.message
			end
			return true, get_maintenance(instance)
		end

		def resize_instance(name, type)
			if dbi = resolve_instance(name)
				return resize_instance_type(dbi, type)
			end
			return false, "Instance #{name} not found"
		end

		def resize_instance_type(instance, type)
			begin
				instance = instance.modify({
					apply_immediately: false,
					db_instance_class: type,
				})
			rescue => e
				return false, e.message
			end
			return true, get_maintenance(instance)
		end

		def get_backup(instance)
			bw = instance.preferred_backup_window()
			start = bw.split("-")[0]
			slocal = Time.parse("#{start} UTC").getlocal()
			return "#{slocal.strftime("%I:%M%p")}"
		end

		def set_backup(name, tstring)
			if dbi = resolve_instance(name)
				return set_instance_backup(dbi, tstring)
			end
			return false, "Instance #{name} not found"
		end

		def set_instance_backup(instance, tstring)
			b = Time.parse(tstring)
			u_start = b.utc()
			u_end = u_start + 30*60
			w_start = u_start.strftime("%H:%M")
			w_end = u_end.strftime("%H:%M")
			begin
				instance = instance.modify({
					apply_immediately: true,
					preferred_backup_window: "#{w_start}-#{w_end}"
				})
			rescue => e
				return false, e.message
			end
			return true, get_backup(instance)
		end

		def get_maintenance(instance)
			mw = instance.preferred_maintenance_window()
			start = mw.split("-")[0]
			sday = start.split(":")[0]
			stime = start.split(":")[1,2].join(":")
			sdt = DateTime.parse("#{sday} #{stime} UTC").to_time().getlocal()
			day = sdt.strftime("%a").downcase()
			return "#{day} #{sdt.strftime("%I:%M%p")}"
		end

		def set_maintenance(name, dstring, tstring)
			if dbi = resolve_instance(name)
				return set_instance_maintenance(dbi, dstring, tstring)
			end
			return false, "Instance #{name} not found"
		end

		def set_instance_maintenance(instance, dstring, tstring)
			tz = Time.now().strftime("%Z")
			b = DateTime.parse("#{dstring} #{tstring} #{tz}")
			u_start = b.to_time().utc()
			u_end = u_start + 30*60
			w_start = u_start.strftime("%a:%H:%M").downcase()
			w_end = u_end.strftime("%a:%H:%M").downcase()
			begin
				instance = instance.modify({
					apply_immediately: true,
					preferred_maintenance_window: "#{w_start}-#{w_end}"
				})
			rescue => e
				return false, e.message
			end
			return true, get_maintenance(instance)
		end

		def resolve_snapshot(snapname)
			begin
				s = @resource.db_snapshots({ db_snapshot_identifier: snapname }).first
				if get_tag(s, "Domain") == @mgr["DNSDomain"]
					return s
				end
			rescue
			end
			return nil
		end

		def delete_snapshot(snapname)
			snap = resolve_snapshot(snapname)
			if snap
				begin
					snap = snap.delete()
				rescue => e
					yield "#{@mgr.timestamp()} Error deleting snapshot: #{e.message}"
					return nil
				end
				yield "#{@mgr.timestamp()} Deleted snapshot #{snap.db_snapshot_identifier}"
				return snap
			else
				yield "#{@mgr.timestamp()} Unable to resolve database snapshot #{snapname}"
				return nil
			end
		end

		def list_instances()
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
			return nil
		end

		def list_snapshots(name=nil, type=nil)
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
					if type
						if get_tag(s, "SnapshotType") == type
							dbsnapshots << s
						end
					else
						dbsnapshots << s
					end
				end
			end
			return dbsnapshots
		end

		def create_snapshot(name=nil, snaptype="manual")
			if name
				@mgr.normalize(name)
			end
			name, dbname = @mgr.getparams("name", "dbname")

			dbinstance = resolve_instance()
			unless dbinstance
				yield "#{@mgr.timestamp()} Unable to resolve db instance: #{name}"
				return false
			end
			snapname = "#{dbname}-#{snaptype}-#{@mgr.timestamp()}"
			snaptags = [ { key: "SnapshotType", value: snaptype } ]
			tags = @client.list_tags_for_resource({ resource_name: dbinstance.db_instance_arn }).tag_list
			tags.each() do |tag|
				snaptags << { key: tag.key, value: tag.value }
			end
			yield "#{@mgr.timestamp()} Creating snapshot #{snapname} for #{name}"
			params = {
				db_snapshot_identifier: snapname,
				tags: snaptags,
			}
			dbinstance.create_snapshot(params)
			return true
		end

		def list_types()
			Dir::chdir("rds") do
				Dir::glob("*.yaml").map() { |t| t[0,t.index(".yaml")] }
			end
		end

		def get_metadata(template)
			templatefile = nil
			if template.end_with?(".yaml")
				templatefile = template
			else
				templatefile = "rds/#{template}.yaml"
			end
			begin
				raw = File::read(templatefile)
				data = YAML::load(raw)
				return data["metadata"], nil if data["metadata"]
				return nil, "No metadata found for #{template}"
			rescue
				return nil, "Error reading template file #{templatefile}"
			end
		end

		def create_instance(name, rootpass, template, wait=true)
			@mgr.setparam("name", name)
			@mgr.setparam("rootpassword", rootpass) # required in the create template
			@mgr.normalize_name_parameters()
			name = @mgr.getparam("name")
			if resolve_instance()
				yield "#{@mgr.timestamp()} Database instance #{name} already exists"
				return nil
			end

			rr = @mgr.route53.lookup(@mgr["PrivateDNSId"])
			if rr.size != 0
				yield "#{@mgr.timestamp()} DNS record for #{name} already exists"
				return nil
			end

			dbname = @mgr.getparam("dbname")
			templatefile = nil
			if template.end_with?(".yaml")
				templatefile = template
			else
				templatefile = "rds/#{template}.yaml"
			end
			begin
				raw = File::read(templatefile)
			rescue
				yield "#{@mgr.timestamp()} Error reading template file #{templatefile}"
				return nil
			end

			raw = @mgr.expand_strings(raw)
			template = YAML::load(raw)
			@mgr.resolve_vars( { "child" => template }, "child" )
			@mgr.symbol_keys(template)

			# TODO: Check for snapshot, use RDS_Restore_Template if so,
			# and delete :db_subnet_group_name, :monitoring_interval,
			# :monitoring_role_arn
			snapname = @mgr.getparam("snapname")
			snapshot = nil
			latest = nil
			if snapname
				snapshot = resolve_snapshot(snapname)
				if snapshot
					yield "#{@mgr.timestamp()} Found requested snapshot #{snapname}"
				else
					yield "#{@mgr.timestamp()} Unable to resolve snapshot #{snapname}"
					return nil
				end
			end
			unless snapshot
				@resource.db_snapshots({ db_instance_identifier: dbname }).each do |s|
					if get_tag(s, "Domain") == @mgr["DNSDomain"]
						unless snapshot
							snapshot = s
							latest = s.snapshot_create_time
						else
							snaptime = s.snapshot_create_time
							if snaptime > latest
								snapshot = s
								latest = snaptime
							end
						end
					end
				end
				if snapshot
					yield "#{@mgr.timestamp()} Found snapshot(s) for #{name}, restoring from #{snapshot.db_snapshot_identifier}"
				end
			else
				yield "#{@mgr.timestamp()} Creating #{name} from provided snapshot #{snapname}"
			end

			# Load the default template
			if snapshot
				apibase = @mgr.expand_strings(RDS_Restore_Template)
			else
				apibase = @mgr.expand_strings(RDS_Default_Template)
			end
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
			dbspec[:tags] = cfgtags.apitags()

			# puts "Options hash:\n#{dbspec}"
			@mgr.lock()
			i, err = resolve_instance()
			if i
				yield "#{@mgr.timestamp()} Instance #{name} already being created"
				@mgr.unlock()
				return nil
			end

			modify_params = {}
			if snapshot
				dbspec.delete(:allocated_storage)
				[ :vpc_security_group_ids, :monitoring_interval, :monitoring_role_arn ].each do |k|
					modify_params[k] = dbspec[k]
					dbspec.delete(k)
				end
				begin
					dbinstance = snapshot.restore(dbspec)
				rescue => e
					@mgr.unlock()
					yield "#{@mgr.timestamp()} Problem restoring database from snapshot: #{e.message}"
					return nil
				end
			else
				begin
					dbinstance = @resource.create_db_instance(dbspec)
				rescue => e
					@mgr.unlock()
					yield "#{@mgr.timestamp()} Problem creating the database: #{e.message}"
					return nil
				end
			end
			@mgr.unlock()
			yield "#{@mgr.timestamp()} Created db instance #{name} (id: #{dbinstance.id()}), waiting for it to become available"
			@client.wait_until(:db_instance_available, db_instance_identifier: dbname)
			if snapshot
				yield "#{@mgr.timestamp()} Modifying restored database with rootpassword and other template values"
				modify_params[:master_user_password] = @mgr.getparam("rootpassword")
				modify_params[:apply_immediately] = true
				begin
					dbinstance.modify(modify_params)
				rescue => e
					yield "#{@mgr.timestamp()} There were non-fatal errors modifying the restored database: #{e.message}"
					dbinstance.modify({
						master_user_password: @mgr.getparam("rootpassword"),
						apply_immediately: true,
					})
					yield "#{@mgr.timestamp()} Modified the database updating only the root password"
				end
				@client.wait_until(:db_instance_available, db_instance_identifier: dbname)
			end
			yield "#{@mgr.timestamp()} #{dbname} is online"

			# Get updated dbinstance with an endpoint
			dbinstance = resolve_instance()

			@mgr.lock()
			rr = @mgr.route53.lookup(@mgr["PrivateDNSId"])
			if rr.size != 0
				yield "#{@mgr.timestamp()} DNS record for #{name} created during build, aborting"
				@mgr.unlock()
				dbinstance.delete({ skip_final_snapshot: true })
				return nil
			end

			update_dns(nil, wait, dbinstance, true) { |s| yield s }

			return dbinstance
		end

		def root_password(name=nil, rootpass)
			if name
				@mgr.setparam("name", name)
				@mgr.normalize_name_parameters()
			end
			name = @mgr.getparam("name")
			dbi = resolve_instance()
			begin
				dbi.modify({
					master_user_password: rootpass,
					apply_immediately: true,
				})
			rescue => e
				return false, "Error updating master password on #{name}: #{e.message}"
			end
			return true, nil
		end

		def delete_instance(name, wait=true, unsafe=false)
			@mgr.setparam("name", name)
			@mgr.normalize_name_parameters()
			name, dbname, fqdn = @mgr.getparams("name", "dbname", "fqdn")
			dbinstance = resolve_instance(nil)

			unless dbinstance
				yield "#{@mgr.timestamp()} Error resolving db instance #{name}"
				return nil
			end

			if unsafe
				yield "#{@mgr.timestamp()} Permanently deleting #{name}"
				dbinstance = dbinstance.delete({ skip_final_snapshot: true })
			else
				snapname = "#{dbname}-#{@mgr.timestamp()}"
				yield "#{@mgr.timestamp()} Creating final snapshot #{snapname} and deleting #{name}"
				dbinstance = dbinstance.delete({
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
			return dbinstance unless wait

			yield "#{@mgr.timestamp()} Waiting for zone to synchronize..."
			@mgr.route53.wait_sync(change_id)
			yield "#{@mgr.timestamp()} Synchronized"
			return dbinstance
		end

		def update_dns(name=nil, wait=false, dbinstance=nil, unlock=false)
			if name
				@mgr.setparam("name", name)
				@mgr.normalize_name_parameters()
			end
			dbinstance = resolve_instance(nil) unless dbinstance

			name = @mgr.getparam("name")
			unless dbinstance
				yield "#{@mgr.timestamp()} Update_dns called on non-existing db instance #{name}"
				return false
			end

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
				yield "#{@mgr.timestamp()} Adding private DNS CNAME record #{cfqdn} -> #{fqdn}"
				change_ids << @mgr.route53.change_records("cname")
			end
			@mgr.unlock() if unlock # Don't hold global lock while waiting for DNS sync
			return true unless wait
			yield "#{@mgr.timestamp()} Waiting for zones to synchronize..."
			change_ids.each() { |id| @mgr.route53.wait_sync(id) }
			yield "#{@mgr.timestamp()} Synchronized"
			return true
		end
	end
end
