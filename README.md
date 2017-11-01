`ruby-awstools` is a set of CLI and API-oriented tools that make it easy to:
* Create and manage a "datacenter in the cloud"
* Create, destroy, start, stop, backup and restore compute instances based on instance templates that define security groups, instance profiles, instance types, and other settings based on a server type; e.g. Apache web, LDAP, Java app server, etc.
* Manage a family of DNS subdomain site repositories, where each subdomain is tagged for easy billing, and can inherit common template definitions from a central repository
* Create and manage a CI/CD environment where instances are created on demand
* Script operations and easily integrate with:
  * Jenkins or other automation applications
  * ChatOps applications
  * Simple cron jobs

Central to the design is a resource model where certain AWS assets and resources are considered long-lived and are normally created and managed with CloudFormation; these include:
* One or more VPCs
* Security Groups
* S3 buckets
* Roles, policies, instance profiles, etc.

Other assets can be managed in a more ephemeral manner based on templates that look up values from CloudFormation, SimpleDB, and site-wide configuration values, and the library can dynamically update Route53 public and VPC private DNS zones. Assets managed in this way include:
* ec2 instances
* rds databases
* route53 records

Similar to Ansible, ruby-awstools keeps templates and data related to a given site / subdomain in a git-commited directory with a defined layout. See the Wiki for more information.
