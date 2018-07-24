module RAWSTools
  class Param
    attr_reader :client

    def initialize(cloudmgr)
      @mgr = cloudmgr
      @client = Aws::SSM::Client.new( @mgr.client_opts )
    end

    def store(key, value, replace=true)
      @client.put_parameter({
        name: key,
        value: value,
        type: "String",
        overwrite: replace,
      })
    end

    def retrieve(key)
      @client.get_parameter({
        name: key,
        with_decryption: false,
      }).parameter.value
    end
  end
end
