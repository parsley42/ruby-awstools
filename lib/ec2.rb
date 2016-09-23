class Ec2
	attr_reader :client, :resource

	def initialize(cloudmgr)
		@mgr = cloudmgr
		@client = Aws::EC2::Client.new( region: @mgr["Region"] )
		@resource = Aws::EC2::Resource.new(client: @client)
		@instances = {}
		@volumes = {}
		@snapshots = {}
	end

	def resolve_instance(must_exist=true, state=nil)
		iname = @mgr.getparam("name")
		if state
			states = [ state ]
		else
			states = [ "pending", "running", "shutting-down", "stopping", "stopped" ]
		end
		return @instances[iname] if @instances[iname]
		f = [
			{ name: "tag:Name", values: [ iname ] },
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
			{
				name: "instance-state-name",
				values: states,
			}
		]
		f << @mgr["Filter"] if @mgr["Filter"]
#		puts "Filter: #{f}"
		instances = @resource.instances(filters: f)
		count = instances.count()
		raise "Multiple matches for Name: #{instance}" if count > 1
		raise "No instance found with Name: #{iname}" if must_exist and count != 1
		return nil if count == 0
		instance = instances.first()
		@instances[iname] = instance
		return instance
	end

	def resolve_volume(must_exist=true)
		vname = @mgr.getparam("volname")
		return @volumes[vname] if @volumes[vname]
		f = [
			{ name: "tag:Name", values: [ vname ] },
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		v = @resource.volumes(filters: f)
		count = v.count()
		raise "Multiple matches for Name: #{volume}" if count > 1
		raise "No volume found with Name: #{volume}" if must_exist and count != 1
		return nil if count == 0
		volume = v.first()
		@volumes[vname] = volume
		return volume
	end

	# NOTE: snapshots should all have fqdns of the form <timestamp>.<name>, where
	# <name> is the fqdn of the volume snapshotted.
	def resolve_snapshot(must_exist=true)
		raise "Rewrite me"
		f = [ { name: "tag:Name", values: [ @mgr.getparam("snapname") ] } ]
		f << @mgr["Filter"] if @mgr["Filter"]
		s = @resource.snapshots(filters: f)
		count = s.count()
		raise "Multiple matches for Name: #{snapshot}" if count > 1
		raise "No snapshot found with Name: #{snapshot}" if must_exist and count != 1
		return nil if count == 0
		return s.first().id()
	end

	def create_volume(size, wait=true)
		raise "Rewrite me"
		snapshot = @mgr.getparam("snapname")
		volname = @mgr.getparam("volname")
		raise "No size or snapshot specified calling create_volume" unless size or snapshot
		voltype = @mgr.expand_strings("${@volume_type:${DefaultVolumeType}}")
		az = @mgr.expand_strings("${Region}${@az}").downcase()
		volspec = {
			availability_zone: az,
			volume_type: voltype,
		}
		if snapshot
			volspec[:snapshot_id] = resolve_snapshot()
		else
			volspec[:encrypted] = true
		end
		volspec[:size] = size if size
		if voltype.downcase() == "io1"
			iops = @mgr.getparam("iops")
			raise "No iops parameter specified for volume type io1" unless iops
			volspec[:iops] = iops
		end
		vol = @resource.create_volume(volspec)
		@client.wait_until(:volume_available, volume_ids: [ vol.id() ]) if wait
		@volumes[volname] = volume
		cfgtags = @mgr.tags()
		cfgtags["Name"] = @mgr.getparam("name")
		cfgtags["Domain"] = @mgr["DNSDomain"]
		vol.create_tags(tags: cfgtags.ltags())
		return vol
	end

	def attach_volume()
		instance = resolve_instance()
		volume = resolve_volume()
		last = "f"
		instance.block_device_mappings.each() do |b|
			d = b.device_name[-1]
			next if d == "1"
			next if d <= last
			last = d
		end
		raise "Too many volumes attached to #{instance}" if last == "p"
		dev = last.next()
		instance.attach_volume({
			volume_id: volume.id(),
			device: "/dev/sd#{dev.next()}",
		})
		@client.wait_until(:volume_in_use, volume_ids: [ volume ])
	end

	def create_instance(template, wait=true)
		@mgr.normalize_name_parameters()
		name, volname, snapname, datasize, availability_zone, dryrun = @mgr.getparams("name", "volname", "snapname", "datasize", "availability_zone", "dryrun")
		raise "Instance #{name} already exists" if resolve_instance(false)
		templatefile = nil
		if template.end_with?(".yaml")
			templatefile = template
		else
			templatefile = "ec2/#{template}.yaml"
		end
		raw = File::read(templatefile)

		raise "Invalid parameters: volume provided with snapshot and/or data size" if volname and snapname or datasize
		if dryrun == "true" or dryrun == true
			dry_run = true
		else
			dry_run = false
		end

		if volname
			yield "Looking up volume: #{@mgr.getparam("volname")}"
			volume=resolve_volume()
		else
			volname = @mgr.getparam("name")
			@mgr.setparam("volname", volname)
			volume=resolve_volume(false)
			if volume
				yield "Found existing volume: #{volname}"
			end
		end

		if volume
			vol_az = volume.availability_zone()
			if availability_zone and availability_zone != vol_az
				yield "Overriding provided availability zone \"#{availability_zone}\" with zone from volume \"#{volname}\": #{vol_az}"
			end
			az = vol_az[-1].upcase()
			@mgr.setparam("az", az)
			@mgr.setparam("availability_zone", vol_az)
		else
			az = @mgr["AvailabilityZones"].sample().upcase()
			availability_zone = @mgr["Region"] + az.downcase()
			yield "Picked random availability zone: #{availability_zone}"
			@mgr.setparam("az", az)
			@mgr.setparam("availability_zone", availability_zone)
		end

		raw = @mgr.expand_strings(raw)
		ispec = YAML::load(raw)
		@mgr.resolve_vars( { "child" => ispec }, "child" )
		@mgr.symbol_keys(ispec)

		if ispec[:user_data]
			ispec[:user_data] = Base64::encode64(ispec[:user_data])
		end

		if ispec[:block_device_mappings]
			ispec[:block_device_mappings].delete_if() do |dev|
				if dev[:device_name].end_with?("a")
					false
				elsif dev[:device_name].end_with?("a1")
					false
				elsif volume
					true
				else
					e=dev[:ebs]
					e.delete(:snapshot_id) unless snapname
					e.delete(:iops) unless e[:volume_type] == "io1"
					e.delete(:encrypted) if snapname
					false
				end
			end
		end
		yield "Dry run, creating: #{ispec}" if dry_run

		instances = @resource.create_instances(ispec)
		instance = nil
		unless dry_run
			instance = instances.first()
			yield "Created instance \"#{name}\" (id: #{instance.id()}), waiting for it to enter state \"running\" ..."
			instance.wait_until_running()
			@client.wait_until(:instance_running, instance_ids: [ instance.id() ])
			yield "Running"

			if volume
				yield "Attaching data volume: #{volname}"
				instance.attach_volume({
					volume_id: volume.id(),
					device: "/dev/sdf",
				})
				@client.wait_until(:volume_in_use, volume_ids: [ volume.id() ])
			end

			# Need to refresh 
			instance = @resource.instance(instance.id())
			@instances[name] = instance

			cfgtags = @mgr.tags()
			cfgtags["Name"] = @mgr.getparam("name")
			cfgtags["Domain"] = @mgr["DNSDomain"]

			instance.create_tags(tags: cfgtags.ltags())

			cfgtags["InstanceName"] = @mgr.getparam("name")
			instance.block_device_mappings().each() do |b|
				if b.device_name.end_with?("a") or b.device_name.end_with?("a1")
					cfgtags["Name"] = "#{@mgr.getparam("name")}-root"
				else
					cfgtags["Name"] = @mgr.getparam("name")
				end
				@resource.volume(b.ebs.volume_id()).create_tags(tags: cfgtags.ltags())
			end
			unless @mgr.getparam("nodns")
				yield "Updating DNS"
				yield "Waiting for zones to synchronize..." if wait
				update_dns(wait)
				yield "Synchronized" if wait
			end
		end
		return instance
	end

	def start_instance(wait=true)
		@mgr.normalize_name_parameters()
		instance = resolve_instance(true, "stopped")
		instance.start()
		update_dns(wait) unless @mgr.getparam("nodns")
		return unless wait
		instance.wait_until_running()
	end

	def stop_instance(wait=true)
		@mgr.normalize_name_parameters()
		instance = resolve_instance(true, "running")
		instance.stop()
		remove_dns(wait)
		return unless wait
		instance.wait_until_stopped()
	end

	def terminate_instance(wait=true)
		@mgr.normalize_name_parameters()
		instance = resolve_instance()
		instance.terminate()
		remove_dns(wait)
		return unless wait
		instance.wait_until_terminated()
	end

	def delete_volume( wait=true)
		volume = resolve_volume_id(volume)
		v = @resource.intstance(volume)
		v.delete()
		return unless wait
		@client.wait_until(:volume_deleted, volume_ids: [ v.id() ])
	end

	def remove_dns(wait=false)
		@mgr.normalize_name_parameters()
		instance = resolve_instance()

		pub_ip = instance.public_ip_address
		priv_ip = instance.private_ip_address

		pubzone = @mgr["PublicDNSId"]
		privzone = @mgr["PrivateDNSId"]

		change_ids = []
		if pub_ip and pubzone
			change_ids << @mgr.route53.delete(pubzone)
		end
		if priv_ip and privzone
			change_ids << @mgr.route53.delete(privzone)
		end
		return unless wait
		change_ids.each() { |id| @mgr.route53.wait_sync(id) }
	end

	def update_dns(wait=false)
		@mgr.normalize_name_parameters()
		instance = resolve_instance()
		pub_ip = instance.public_ip_address
		priv_ip = instance.private_ip_address

		pubzone = @mgr["PublicDNSId"]
		privzone = @mgr["PrivateDNSId"]

		change_ids = []
		if pub_ip and pubzone
			@mgr.setparam("zone_id", pubzone)
			@mgr.setparam("ipaddr", pub_ip)
			change_ids << @mgr.route53.change_records("arec")
		end
		if priv_ip and privzone
			@mgr.setparam("zone_id", privzone)
			@mgr.setparam("ipaddr", priv_ip)
			change_ids << @mgr.route53.change_records("arec")
		end
		return unless wait
		change_ids.each() { |id| @mgr.route53.wait_sync(id) }
	end
	
	def wait_running()
		instance = resolve_instance()
		@client.wait_until(:instance_running, instance_ids: [ instance.id() ])
	end
end
