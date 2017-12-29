module RAWSTools
  class Route53
    attr_reader :client

    def initialize(cloudmgr)
      @mgr = cloudmgr
      @client = Aws::Route53::Client.new( @mgr.client_opts )
    end

    # Wrapper that will retry on rate exceeded
    def change_record_sets(set)
      tries = 0
      while true
        begin
          resp = @client.change_resource_record_sets(set)
          break
        rescue => e
          tries += 1
          if /rate exceed/i =~ e.message
            if tries >= 4
              raise e
            end
            @mgr.log(:debug, "Caught exception in change_resource_record_sets: #{e.message}, retrying")
            sleep 2 * tries
          elsif /rate for operation/i =~ e.message or /ServiceUnavailable/i =~ e.message
            if tries >= 4
              raise e
            end
            @mgr.log(:debug, "Caught exception in change_resource_record_sets: #{e.message}, retrying")
            sleep 30
          else
            raise e
          end
        end
      end
      return resp
    end

    # Wrapper that will retry on rate exceeded
    def list_record_sets(params)
      tries = 0
      while true
        begin
          resp = @client.list_resource_record_sets(params)
          break
        rescue => e
          if /rate exceed/i =~ e.message or /ServiceUnavailable/i =~ e.message
            tries += 1
            if tries >= 4
              raise e
            end
            @mgr.log(:debug, "Caught exception in list_resource_record_sets: #{e.message}, retrying")
            sleep 2 & tries
          else
            raise e
          end
        end
      end
      return resp
    end

    def lookup(zone, fqdn = nil, type=nil)
      @mgr.normalize_name_parameters()
      fqdn = @mgr.getparam("fqdn") unless fqdn
      @mgr.log(:debug, "Looking up #{fqdn} in #{zone}")
      raise "No fqdn parameter or function argument; missing a call to normalize_name_parameters?" unless fqdn
      lookup = {
        hosted_zone_id: zone,
        start_record_name: fqdn,
        max_items: 1,
      }
      lookup[:start_record_type] = type if type
      records = list_record_sets(lookup)
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
      records = list_record_sets(lookup)
      record = records.resource_record_sets[0]
      return unless record and record.name == fqdn
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
      resp = change_record_sets(dset)
      return resp
    end

    def change_records(type)
      # Note: call to normalize_name_parameters removed as it interfered
      # with CNAME records that pointed somewhere else. The caller should
      # use normalize_name_parameters if needed.
      begin
        template = @mgr.load_template("route53", type)
      rescue => e
        msg = "Caught exception loading route53 template #{type}: #{e.message}"
        yield "#{@mgr.timestamp()} #{msg}"
        return nil, msg
      end
      @mgr.symbol_keys(template)
      @mgr.resolve_vars(template, :api_template)

      set = template[:api_template]
      @mgr.log(:debug, "Submitting change_record_sets with:\n#{set}")
      resp = change_record_sets(set)
      return resp
    end

    def wait_sync(change)
      @client.wait_until(:resource_record_sets_changed, id: change.change_info.id )
    end
  end
end
