class Ec2
	attr_reader :client, :resource

	def initialize(cloudmgr)
		@mgr = cloudmgr
		@client = Aws::EC2::Client.new( region: @mgr["Region"] )
		@resource = Aws::EC2::Resource.new(client: @client)
		@instances = {}
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
		instances = @resource.instances(filters: f)
		count = instances.count()
		raise "Multiple matches for Name: #{instance}" if count > 1
		raise "No instance found with Name: #{iname}" if must_exist and count != 1
		return nil if count == 0
		instance = instances.first()
		@instances[iname] = instance
		return instance
	end

	def list_instances(states=nil)
		states = [ "pending", "running", "shutting-down", "stopping", "stopped" ] unless states
		f = [
			{ name: "instance-state-name", values: states },
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		instances = @resource.instances(filters: f)
		return instances
	end

	def get_tag(item, tagname)
		item.tags.each() do |tag|
			return tag.value if tag.key == tagname
		end
	end

	def resolve_volume(must_exist=true, status=[ "available" ] )
		vname = @mgr.getparam("volname")
		f = [
			{ name: "tag:Name", values: [ vname ] },
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
			{ name: "status", values: status },
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		v = @resource.volumes(filters: f)
		count = v.count()
		raise "Multiple matches for Name: #{volume}" if count > 1
		raise "No volume found with Name: #{volume} and Status: #{status}" if must_exist and count != 1
		return nil if count == 0
		return v.first()
	end

	def list_volumes()
		f = [
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		volumes = @resource.volumes(filters: f)
		return volumes
	end

	# NOTE: snapshots should all have fqdns of the form <timestamp>.<name>, where
	# <name> is the fqdn of the volume snapshotted.
	def resolve_snapshot(must_exist=true)
		sname = @mgr.getparam("snapname")
		f = [
			{ name: "tag:Name", values: [ @mgr.getparam("snapname") ] },
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		s = @resource.snapshots(filters: f)
		count = s.count()
		raise "Multiple matches for Name: #{sname}" if count > 1
		raise "No snapshot found with Name: #{sname}" if must_exist and count != 1
		return nil if count == 0
		return s.first()
	end

	def list_snapshots()
		f = [
			{ name: "tag:Domain", values: [ @mgr["DNSDomain"] ] },
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		snapshots = @resource.snapshots(filters: f)
		return snapshots
	end

	def create_snapshot(wait=false)
		@mgr.normalize_name_parameters()
		volname = @mgr.getparam("volname")
		vol = resolve_volume(true, [ "available", "in-use" ])
		now = Time.new()
		timestamp = now.strftime("%Y%m%d%H%M")
		snapname = "#{volname}.#{timestamp}"
		yield "Creating snapshot #{snapname}"
		snap = vol.create_snapshot()
		tags = vol.tags
		snaptags = []
		tags.each() do |tag|
			if tag.key == "Name"
				snaptags << { "key" => tag.key, "value" => snapname }
			else
				snaptags << { "key" => tag.key, "value" => tag.value }
			end
		end
		yield "Tagging snapshot"
		snap.create_tags(tags: snaptags)
		return unless wait
		yield "Waiting for snapshot to complete"
		snap.wait_until_completed()
		yield "Completed"
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
		cfgtags = @mgr.tags()
		cfgtags["Name"] = @mgr.getparam("name")
		cfgtags["Domain"] = @mgr["DNSDomain"]
		vol.create_tags(tags: cfgtags.ltags())
		return vol
	end

	def attach_volume()
		raise "Rewrite me"
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
		name, volname, snapname, datasize, availability_zone, dryrun, nodns = @mgr.getparams("name", "volname", "snapname", "datasize", "availability_zone", "dryrun", "nodns")
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
				yield "Overriding provided availability zone: #{availability_zone} with zone from volume: #{volname}: #{vol_az}"
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
		template = YAML::load(raw)
		@mgr.resolve_vars( { "child" => template }, "child" )
		@mgr.symbol_keys(template)
		ispec = template[:api_template]

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
					if snapname
						e.delete(:encrypted)
						snapshot = resolve_snapshot()
						e[:snapshot_id] = snapshot.id()
					else
						e.delete(:snapshot_id)
					end
					e.delete(:iops) unless e[:volume_type] == "io1"
					false
				end
			end
		end
		yield "Dry run, creating: #{ispec}" if dry_run

		instances = @resource.create_instances(ispec)
		instance = nil
		unless dry_run
			instance = instances.first()
			yield "Created instance #{name} (id: #{instance.id()}), waiting for it to enter state running ..."
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
			cfgtags.add(template[:tags]) if template[:tags]

			instance.create_tags(tags: cfgtags.ltags())

			yield "Tagging instance"
			cfgtags["InstanceName"] = @mgr.getparam("name")
			instance.block_device_mappings().each() do |b|
				if b.device_name.end_with?("a") or b.device_name.end_with?("a1")
					yield "Tagging root volume"
					cfgtags["Name"] = "#{@mgr.getparam("name")}-root"
				else
					yield "Tagging data volume"
					cfgtags["Name"] = @mgr.getparam("name")
				end
				@resource.volume(b.ebs.volume_id()).create_tags(tags: cfgtags.ltags())
			end
			update_dns(wait) { |s| yield s }
		end
		return instance
	end

	def start_instance(wait=true)
		@mgr.normalize_name_parameters()
		name, nodns = @mgr.getparams("name", "nodns")
		instance = resolve_instance(false, "stopped")
		if instance
			yield "Starting #{name}"
			instance.start()
			yield "Started instance #{name} (id: #{instance.id()}), waiting for it to enter state running ..."
			instance.wait_until_running()
			# Need to refresh
			instance = @resource.instance(instance.id())
			@instances[name] = instance

			update_dns(wait) { |s| yield s }
		else
			yield "No stopped instance found with Name: #{name}"
		end
	end

	def stop_instance(wait=true)
		@mgr.normalize_name_parameters()
		name = @mgr.getparam("name")
		instance = resolve_instance(false, "running")
		if instance
			yield "Stopping #{name}"
			instance.stop()
			remove_dns(wait) { |s| yield s }
			return unless wait
			yield "Waiting for instance to stop..."
			instance.wait_until_stopped()
			yield "Stopped"
		else
			yield "No running instance found with Name: #{name}"
		end
	end

	def terminate_instance(wait=true, deletevol=false)
		@mgr.normalize_name_parameters()
		name = @mgr.getparam("name")
		instance = resolve_instance(false, "running")
		if instance
			yield "Terminating #{name}"
			instance.terminate()
			remove_dns(wait) { |s| yield s }
			return unless wait or deletevol
			yield "Waiting for instance to terminate..."
			instance.wait_until_terminated()
			yield "Terminated"
			@mgr.setparam("volname", name)
			delete_volume(wait) { |s| yield s } if deletevol
		else
			yield "No running instance found with Name: #{name}"
		end
	end

	def delete_volume(wait=true)
		@mgr.normalize_name_parameters()
		volname = @mgr.getparam("volname")
		volume = resolve_volume(false)
		if volume
			yield "Deleting volume: #{volname}"
			volume.delete()
			return unless wait
			yield "Waiting for volume to finished deleting..."
			@client.wait_until(:volume_deleted, volume_ids: [ volume.id() ])
			yield "Deleted"
		else
			yield "Not deleting volume - no volume found with Name: #{volname} and Status: available"
		end
	end

	def remove_dns(wait=false)
		@mgr.normalize_name_parameters()
		instance = resolve_instance()
		name = @mgr.getparam("name")

		pub_ip = instance.public_ip_address
		priv_ip = instance.private_ip_address

		pubzone = @mgr["PublicDNSId"]
		privzone = @mgr["PrivateDNSId"]

		change_ids = []
		if pub_ip and pubzone
			yield "Removing public DNS record #{name} -> #{pub_ip}"
			change_ids << @mgr.route53.delete(pubzone)
		end
		if priv_ip and privzone
			yield "Removing private DNS record #{name} -> #{priv_ip}"
			change_ids << @mgr.route53.delete(privzone)
		end
		return unless wait
		yield "Waiting for zones to synchronize..."
		change_ids.each() { |id| @mgr.route53.wait_sync(id) }
		yield "Synchronized"
	end

	def update_dns(wait=false)
		@mgr.normalize_name_parameters()
		name, nodns = @mgr.getparams("name", "nodns")
		unless nodns
			instance = resolve_instance()
			pub_ip = instance.public_ip_address
			priv_ip = instance.private_ip_address

			pubzone = @mgr["PublicDNSId"]
			privzone = @mgr["PrivateDNSId"]

			change_ids = []
			if pub_ip and pubzone
				@mgr.setparam("zone_id", pubzone)
				@mgr.setparam("ipaddr", pub_ip)
				yield "Adding public DNS record #{name} -> #{pub_ip}"
				change_ids << @mgr.route53.change_records("arec")
			end
			if priv_ip and privzone
				@mgr.setparam("zone_id", privzone)
				@mgr.setparam("ipaddr", priv_ip)
				yield "Adding private DNS record #{name} -> #{priv_ip}"
				change_ids << @mgr.route53.change_records("arec")
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
