## How Parameters are Used

One complicating factor for the problem of creating and managing ec2 instances, rds databases, and other AWS resources is that the number of possible parameters that could be specified is high. The possibility also exists that a given user may want to parameterize a value (such as "disable_api_termination") for instance types where another user will simply want to set a default value and not otherwise specify a value, or might want to use a default value if none is otherwise specified.

For instance, if a user wanted to add this parameter for an `ldap` server type, `ldap.yaml` could include:
```yaml
api_template:
  ...
  disable_api_termination: ${@no_api_term|true}
  ...
```
The `${@no_api_term|true}` syntax is interpreted as:
* Use the value of the `no_api_term` parameter if it is set
* Otherwise use `true` as the default

Then, launching an `ldap` server from the command line would either be:
```
ec2 create ldap1 myEC2Keyname ldap
```
... to create a normal ldap server with api termination disabled, or:
```
ec2 create -p no_api_term=false ldap2 myEC2Keyname ldap
```
... to create an ldap server that doesn't.

In the library, this is implemented by the get/set_param* family of methods on CloudManager. Thus, method calls mainly take a small number of required arguments, and other parameters are either checked by cfg.get_param*() calls, or referenced during template expansion. Thus, creating the ldap server in the first code would result in code similar to:
```ruby
require 'rawstools'

cfg = RAWSTools::CloudManager.new()

cfg.ec2.create_instance("ldap1", "myEC2keyname", "ldap")
```
... or in the second case:
```ruby
require 'rawstools'

cfg = RAWSTools::CloudManager.new()

cfg.setparam("no_api_term", false)
cfg.ec2.create_instance("ldap1", "myEC2keyname", "ldap")
```