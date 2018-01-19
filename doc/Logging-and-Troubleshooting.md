## Adjusting the Log Level

`ruby-awstools` has recently adopted a fairly standard logging configuration, where the log level can be one of `trace`, `debug`, `info`, `warn`, and `error`, and the default is `info`. To troubleshoot, you can export a value for `RAWS_LOGLEVEL`:
```shell
$ export RAWS_LOGLEVEL=trace
$ irb
irb(main):001:0> require 'rawstools'
=> true
irb(main):002:0> cfg=RAWSTools::CloudManager.new()
Looking for /home/foo/git/ruby-awstools/lib/rawstools/templates/cloudconfig.yaml
=> Loading /home/foo/git/ruby-awstools/lib/rawstools/templates/cloudconfig.yaml
Looking for ../aws-common/cloudconfig.yaml
=> Loading ../aws-common/cloudconfig.yaml
Looking for ./cloudconfig.yaml
=> Loading ./cloudconfig.yaml
Resolving values for key: Tags
Resolving values for key: Project
...
```