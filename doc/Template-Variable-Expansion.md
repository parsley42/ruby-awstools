## Template String Expansion

`ruby-awstools` is heavily template based, reading in YAML data structures
which get processed and used in AWS method calls. This guide documents how
values are expanded:

* **${&var}** - retrieve a top-level value from cloudconfig.yaml, for site-wide values
* **${@param(|defaultvalue)}** - use the value of a parameter, or the default value if the
  parameter isn't set
* **${=Template(:child):Output(|defaultvalue)}** - retrieve an output from a previously-created
  cloudformation template, or use the default value if the lookup fails
* **${%item:key(|defaultvalue)}** - Look up the attribute <key> for <item> in the configured
  ConfigDB (AWS SimpleDB) from the cloud config. Mostly useful for retrieving
  AMI ids stored with the `sdb` tool

## Default Values

When expanding API templates, the following default values have special meaning:
* **\<DELETE\>** - delete this key if no value found
* **\<REQUIRED\>** - throw an exception if no value found