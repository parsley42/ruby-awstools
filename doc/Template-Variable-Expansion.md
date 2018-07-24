## Template String Expansion

`ruby-awstools` is heavily template based, reading in YAML data structures
which get processed and used in AWS method calls. This guide documents how
values are expanded:

* **${&var}** - Retrieve a top-level value from cloudconfig.yaml, for site-wide values.
* **${@param(|defaultvalue)}** - Use the value of a parameter, or the default value if the
  parameter isn't set.
* **${=Stack(:Stack...):Resource(.property)(|defaultvalue)}** - Retrieve a resource value (e.g. security group ID) from a previously-created cloudformation template, or use the default value if the lookup fails. Stacks and resources can be explored with the 'cfn' CLI tool.
* **${~ENV_VAR|defaultvalue}** - Retrieve a value from an environment variable.
* **${%item:key(|defaultvalue)}** - Look up the attribute <key> for <item> in the configured
  ConfigDB (AWS SimpleDB) from the cloud config. Mostly useful for retrieving
  AMI ids stored with the `sdb` tool
* **${^param(|defaultvalue)}** - Look up the key from SSM parameter store

## Default Values

When expanding API templates, the following default values have special meaning:
* **\<DELETE\>** - delete this key if no value found
* **\<REQUIRED\>** - throw an exception if no value found

## Complex Data Element Expansion
After parsing the YAML into a data structure, `ruby-awstools` walks the
tree and looks for right-hand-side string elements of the form `$var`/`$@param`/`$%item:key`.
This allows you to replace array elements and hash values with arbitrarily
complex data structures from the cloud config file or generated parameter
structures; e.g. an array of hashes.

* $var - look up data structure in the cloud config file.
* $@param - look up complex parameter; this must be created and set by the
  tool and is only for special cases such as TXT records, where the string
  value must be split into an array of 255-char substrings.
* $%item:key - look up value(s) from a SimpleDB domain, defaulting to the
  value of ConfigDB in the cloud config file.