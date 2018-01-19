AWSTools is heavily designed around using YAML-formatted templates which define options used in API calls. Many AWS API calls take complex data structures consisting of hashes and arrays. Instead of doing a lot of hand-coding of the contents of these data structures, we load the data structures from YAML file templates, starting with a default template included in the library, and overlaying with more specific templates up to and including a type-specific template. Thus, if a particular site is mostly concerned with creating bastion hosts, ldap servers, and apache web servers, the user would create templates with names like "ldap.yaml", "apache.yaml", and "bastion.yaml" that would define values for security groups, subnets, instance types, etc. Values for e.g. "disable_api_termination" could be inherited from site-wide values.

One advantage is in flexibility to define a wide variety of arbitrary values in templates, so an individual user could e.g. define kms options, or reference a custom parameter. Drawbacks include the possibility that key names may change, and that the templates mostly tie the implementation to a specific language (ruby).

Note that the content here doesn't apply to `cfn` (the CloudFormation tool), but only to ec2, rds, and route53. Also, route53 needs more design thought.

## Template loading algorithm
Scripts and tools call <mgr>.load_template(facility, type), where "facility" is ec2, rds, or route53, and
"type" is the name of a custom resource type (e.g. "linux_apache", or "mariadb_high_perf").

1. Templates are loaded in the default-to-specific order listed below, with values from later, more
specific templates replacing values from earlier, more default templates:
   1. Library default templates from templates/<facility>/<facility>.yaml
   1. For each path listed in the configured `SearchPath` array:
      1. \<path\>/\<facility\>/\<facility\>.yaml
      1. \<path>/\<facility\>/\<name\>.yaml
   1. In the project repository:
      1. \<path\>/\<facility\>/\<facility\>.yaml
      1. \<path>/\<facility\>/\<name\>.yaml

1. During load, second-level hashes of successive loads override earlier loads; e.g. items defined under "metadata" replace previously defined items, but "metadata" from the project repository doesn't completely replace "metadata" found in the search path
1. Value strings are expanded in a later step, as library calls may manipulate api templates to achieve
various behaviors; e.g. removing a default block device when launching from a snapshot, etc.

## Template file directory structure and naming
- Each location where template files can be loaded (lib defaults, search path, repository) should have
sub-directories for each facility - "ec2", "rds", and "route53".
- Default templates should be in yaml files in the facility directory with the same name as the facility,
e.g. `rds/rds.yaml`
- Customized templates (for a given "type" of ec2 instance, rds database, etc.) should be yaml files in the facility directory with names of the form `<mytype>.yaml` that reflect the type, e.g. `mariadb_high_perf.yaml`

e.g.:
```
rds/
  rds.yaml
  my_rds_type.yaml
ec2/
  ec2.yaml
  my_ec2_type.yaml
```

## Template internal file structure
Each template file is a hash at the first two levels; the library normally looks for an "api_template"
hash key that defines all the values for creating a resource with a given facility. Other top-level keys
like "metadata" are informational for a specific implementation.