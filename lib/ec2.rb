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

	def resolve_instance(must_exist=true)
		iname = @mgr.getparam("name")
		return @instances[iname] if @instances[iname]
		fqdn = @mgr.getparam("fqdn")
		f = [
			{ name: "tag:FQDN", values: [ fqdn ] },
			{
				name: "instance-state-name",
				values: [ "pending", "running", "shutting-down", "stopping", "stopped" ],
			}
		]
		f << @mgr["Filter"] if @mgr["Filter"]
		idata = @resource.instances(filters: f)
		count = idata.count()
		raise "Multiple matches for Name: #{instance}" if count > 1
		raise "No instance found with Name: #{instance}" if must_exist and count != 1
		return nil if count == 0
		instance = idata.first()
		@instances[i] = instance
		return instance
	end

	def resolve_volume(must_exist=true)
		vname = @mgr.getparam("volname")
		return @volumes[vname] if @volumes[vname]
		iname = @mgr.getparam("name")
		f = [ { name: "tag:InstanceName", values: [ vname ] } ]
		f << @mgr["Filter"] if @mgr["Filter"]
		v = @resource.volumes(filters: f)
		count = v.count()
		if count == 0
			f = [ { name: "tag:Name", values: [ @mgr.getparam("name") ] } ]
			f << @mgr["Filter"] if @mgr["Filter"]
			v = @resource.volumes(filters: f)
			count = v.count()
		end
		raise "Multiple matches for Name: #{volume}" if count > 1
		raise "No volume found with Name: #{volume}" if must_exist and count != 1
		return nil if count == 0
		return v.first().id()
	end

	# NOTE: snapshots should all have fqdns of the form <timestamp>.<name>, where
	# <name> is the fqdn of the volume snapshotted.
	def resolve_snapshot(must_exist=true)
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
		cfgtags["FQDN"] = @mgr.getparam("fqdn")
		vol.create_tags(tags: cfgtags.ltags())
		return vol
	end

	def attach_volume()
		instance = resolve_instance_id(@mgr.getparam("name"))
		volume = resolve_volume_id(@mgr.getparam("volname"))
		idata = @resource.instance(instance)
		last = "f"
		idata.block_device_mappings.each() do |b|
			d = b.device_name[-1]
			next if d == "1"
			next if d <= last
			last = d
		end
		raise "Too many volumes attached to #{instance}" if last == "p"
		dev = last.next()
		idata.attach_volume({
			volume_id: volume,
			device: "/dev/sd#{dev.next()}",
		})
		@client.wait_until(:volume_in_use, volume_ids: [ volume ])
	end

	def create_instance_from_template(template)
		templatefile = nil
		if template.end_with?(".yaml")
			templatefile = template
		else
			templatefile = "ec2/#{template}.yaml"
		end
		raw = File::read(templatefile)
		raw = @mgr.expand_strings(raw)
		ispec = YAML::load(raw)

		@mgr.resolve_vars( { "child" => ispec }, "child" )
		@mgr.symbol_keys(ispec)
		if ispec[:user_data]
			ispec[:user_data] = Base64::encode64(ispec[:user_data])
		end
		#puts "Creating: #{ispec}"

		instances = @resource.create_instances(ispec)
		return instances.first()
	end

	def tag_instance_resources()
		instance = resolve_instance()
		cfgtags = @mgr.tags()
		cfgtags["Name"] = @mgr.getparam("name")
		cfgtags["FQDN"] = @mgr.getparam("fqdn")

		instance.create_tags(tags: cfgtags.ltags())

		idata.block_device_mappings().each() do |b|
			next unless b.device_name.end_with?("a") or b.device_name.end_with?("1")
			cfgtags["Name"] = "rootvol-#{@mgr.getparam("name")}"
			cfgtags["InstanceName"] = @mgr.getparam("name")
			@resource.volume(b.ebs.volume_id()).create_tags(tags: cfgtags.ltags())
		end
	end

	def start_instance(wait=true)
		instance = resolve_instance_id(instance)
		i = @resource.intstance(instance)
		i.start()
		return unless wait
		@client.wait_until(:instance_running, instance_ids: [ i.id() ])
	end

	def stop_instance(wait=true)
		instance = resolve_instance_id(instance)
		i = @resource.intstance(instance)
		i.stop()
		return unless wait
		@client.wait_until(:instance_stopped, instance_ids: [ i.id() ])
	end

	def terminate_instance(wait=true)
		instance = resolve_instance_id(instance)
		i = @resource.intstance(instance)
		i.terminate()
		return unless wait
		@client.wait_until(:instance_terminated, instance_ids: [ i.id() ])
	end

	def delete_volume( wait=true)
		volume = resolve_volume_id(volume)
		v = @resource.intstance(volume)
		v.delete()
		return unless wait
		@client.wait_until(:volume_deleted, volume_ids: [ v.id() ])
	end

	def remove_dns(wait=false)
		instance = resolve_instance_id(instance)
		i = @resource.intstance(instance)
		dnsname = nil
		i.tags.each() do |tag|
			if tag.key() == "Name"
				dnsname = tag.value() + "." + @mgr["DNSBase"] + "."
				break
			end
		end
		return unless dnsname

		pub_ip = i.public_ip_address
		priv_ip = i.private_ip_address

		pubzone = @mgr["PublicDNSId"]
		privzone = @mgr["PrivateDNSId"]

		change_ids = []
		if pub_ip and pubzone
			change_ids << @mgr.route53.delete(dnsname, pubzone)
		end
		if priv_ip and privzone
			change_ids << @mgr.route53.delete(dnsname, privzone)
		end
		return unless wait
		change_ids.each() { |id| @mgr.route53.wait_sync(id) }
	end

	def update_dns(wait=false)
		instance = resolve_instance_id(instance)
		i = @resource.instance(instance)
		unless @mgr.getparam("name")
			i.tags.each() do |tag|
				if tag.key() == "Name"
					@mgr.setparam("name", tag.value())
					@mgr.normalize_name_parameters()
					break
				end
			end
		end
		pub_ip = i.public_ip_address
		priv_ip = i.private_ip_address

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
		instance = resolve_instance_id(instance)
		@client.wait_until(:instance_running, instance_ids: [ instance ])
	end
end
