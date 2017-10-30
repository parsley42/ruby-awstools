module RAWSTools

  # key lists for pruning api_templates
  Aurora_Cluster_Keys = [ :availability_zones, :backup_retention_period,
    :character_set_name, :database_name, :db_cluster_identifier,
    :db_cluster_parameter_group_name, :vpc_security_group_ids,
    :db_subnet_group_name, :engine, :engine_version, :port, :master_username,
    :master_user_password, :option_group_name, :preferred_backup_window,
    :preferred_maintenance_window, :replication_source_identifier,
    :tags, :storage_encrypted, :kms_key_id, :pre_signed_url,
    :enable_iam_database_authentication, :destination_region,
    :source_region
  ]
  # NOTE: removed :storage_type and :iops, which don't appear to apply
  Aurora_Instance_Keys = [ :db_name, :db_instance_identifier,
    :db_instance_class, :engine, :db_security_groups, :availability_zone,
    :db_subnet_group_name, :preferred_maintenance_window,
    :db_parameter_group_name, :port, :multi_az, :auto_minor_version_upgrade,
    :license_model, :option_group_name, :publicly_accessible,
    :tags, :db_cluster_identifier, :tde_credential_arn,
    :tde_credential_password, :domain, :copy_tags_to_snapshot,
    :monitoring_interval, :monitoring_role_arn, :domain_iam_role_name,
    :promotion_tier, :enable_performance_insights,
    :performance_insights_kms_key_id
  ]
  DB_Instance_Keys = [ :db_name, :db_instance_identifier, :allocated_storage,
    :db_instance_class, :engine, :master_username, :master_user_password,
    :db_security_groups, :vpc_security_group_ids, :availability_zone,
    :db_subnet_group_name, :preferred_maintenance_window,
    :db_parameter_group_name, :backup_retention_period,
    :preferred_backup_window, :port, :multi_az, :auto_minor_version_upgrade,
    :license_model, :iops, :option_group_name, :character_set_name,
    :publicly_accessible, :tags, :storage_type,
    :tde_credential_arn, :tde_credential_password, :storage_encrypted,
    :kms_key_id, :domain, :copy_tags_to_snapshot, :monitoring_interval,
    :monitoring_role_arn, :domain_iam_role_name, :promotion_tier,
    :timezone, :enable_iam_database_authentication,
    :enable_performance_insights, :performance_insights_kms_key_id
  ]
  DB_Restore_Keys = [
    :db_instance_identifier, :db_instance_class, :port, :availability_zone,
    :db_subnet_group_name, :multi_az, :publicly_accessible,
    :auto_minor_version_upgrade, :license_model, :db_name, :engine,
    :iops, :option_group_name, :tags, :storage_type, :tde_credential_arn,
    :tde_credential_password, :domain, :copy_tags_to_snapshot,
    :domain_iam_role_name, :enable_iam_database_authentication
  ]

	class RDS
		attr_reader :client, :resource
    include RAWSTools

		def initialize(cloudmgr)
			@mgr = cloudmgr
			@client = Aws::RDS::Client.new(region: @mgr["Region"])
			@resource = Aws::RDS::Resource.new(client: @client)
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

    # metadata interpretation is left up to the tool/script using the library
		def get_metadata(type)
      begin
        data = @mgr.load_template("rds", type)
      rescue => e
        msg = "Caught exception loading template: #{e.message}"
				yield "#{@mgr.timestamp()} #{msg}"
				return nil, msg
			end
			return data["metadata"], nil if data["metadata"]
			return nil, "No metadata found for #{template}"
		end

		def create_instance(name, rootpass, type, wait=true)
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

      begin
        base_template = @mgr.load_template("rds", type)
      rescue => e
        msg = "Caught exception loading rds template #{type}: #{e.message}"
        yield "#{@mgr.timestamp()} #{msg}"
        return nil, msg
      end

      # puts "Options hash:\n#{dbspec}"
			@mgr.lock()
			i, err = resolve_instance()
			if i
				yield "#{@mgr.timestamp()} Instance #{name} already exists"
				@mgr.unlock()
				return nil
			end

      @mgr.symbol_keys(base_template)
      @mgr.resolve_vars(base_template, :api_template)
      dbspec = base_template[:api_template]
      dbspec.delete(:iops) unless dbspec[:storage_type] == "io1"
      tags = dbspec[:tags]
			cfgtags = @mgr.tags()
			cfgtags["Name"] = name
			cfgtags["Domain"] = @mgr["DNSDomain"]
			cfgtags.add(tags) if tags
			dbspec[:tags] = cfgtags.apitags()

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

      if dbspec[:engine] == "aurora"
        clspec = dbspec.dup()
        prune_template(clspec, Aurora_Cluster_Keys)
        begin
          resp = @client.create_db_cluster(clspec)
        rescue => e
          @mgr.unlock()
          yield "#{@mgr.timestamp()} Problem creating Aurora cluster: #{e.message}"
          return nil
        end
        yield "#{@mgr.timestamp()} Created Aurora cluster #{name} (id: #{resp.db_cluster.db_cluster_identifier})"
      end

      # Store params for later modify
			modify_params = {}
			if snapshot
				[ :vpc_security_group_ids, :monitoring_interval, :monitoring_role_arn ].each do |k|
					modify_params[k] = dbspec[k]
				end
        prune_template(dbspec, DB_Restore_Keys)
				begin
					dbinstance = snapshot.restore(dbspec)
				rescue => e
					@mgr.unlock()
					yield "#{@mgr.timestamp()} Problem restoring database from snapshot: #{e.message}"
					return nil
				end
			else
				begin
          if dbspec[:engine] == "aurora"
            prune_template(dbspec, Aurora_Instance_Keys)
          else
            prune_template(dbspec, DB_Instance_Keys)
          end
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
        if dbspec[:engine] != "aurora"
          modify_params[:master_user_password] = @mgr.getparam("rootpassword")
        end
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

      cluster_id = dbinstance.db_cluster_identifier()

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

      if cluster_id
        dbcluster = @resource.db_cluster(cluster_id)
        if unsafe
          dbcluster.delete({ skip_final_snapshot: true })
        else
          dbcluster.delete({
            skip_final_snapshot: false,
  					final_db_snapshot_identifier: snapname
          })
        end
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
