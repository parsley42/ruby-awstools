# Overview

`ruby-awstools` consists of a library and various ruby cli scripts using the
Ruby aws-sdk, intended to:
* Simplify creation of AWS resources in a scriptable manner
* Manage sets of CloudFormation stacks
* Centralize configuration data with an aim towards "configuration as code"

## A 'biased' tool

To greatly simplify matters, the library and tools have a number of assumptions
built-in; if any of these don't hold true for your intended use, you may get
only limited functionality:
* VPC's, subnets, security groups, and other long-lived resources will be
  created with CloudFormation templates (with samples provided)
* You will have (or create) AWS-integrated DNS hosted zones, preferably
  public and private zones for the same domain
* Most ec2 instances have a single data volume attached to no more than
  a single instance
* When ec2 instances are started, stopped, created or terminated, DNS will
  be updated at the same time to reflect the current state of the instance
* Most ec2 instances and volumes will be created dynamically with the `ec2`
  CLI tool or via the library; while a CloudFormation-based workflow is
  well supported, most of the work has gone into `ec2` and related classes.

<b>** NOTE: the contents of the sample/ directory are currently outdated **</b>

# Installation
1. Clone the repository
2. Build the gem:
```
$ gem build rawstools.gemspec
```
3. Install the gem:
```
$ gem install rawstools-*.gem
```

# Common Configuration and Conventions

YAML is the standard file-format for `ruby-awstools` configuration files.
If you're unfamiliar with YAML (also used with Ansible), you should
familiarize yourself with it.

## Project Repositories

`ruby-awstools` centers around the idea of a project repository where all
the configuration data and templates for a single-region/VPC AWS presence live
in a single directory with a well-defined format:

```
cloudconfig.yaml - default central configuration file specifying a region, VPC
CIDR, subnet definitions, DNS zone info, etc. (can be overridden with -c, or
$RAWS_CLOUDCFG environment variable)
	cfn/ - subdirectory for cloud formation templates (expanded below in cfn section)
	ec2/ - subdirectory for ec2 instance templates
```

## Variable Expansion

One of the features that makes `ruby-awstools` powerful is it's use of
templates with variable expansion functionality, allowing centralized
configuration data to be retrieved from the cloudconfig.yaml file,
CloudFormation template outputs, DNS, and provided parameters.

### Parameters

`ruby-awstools` is largely based on yaml templates, and many of these templates
take parameters for various options. Since different templates may have different
parameters, these parameters aren't passed as method arguments but rather stored
as a ConfigManager parameter, and expanded in the template through the
${@param(|default)} construct.

#### DNS Zones, Naming, and DNS Parameters

For simplicity, `ruby-awstools` design uses DNS-based naming conventions
where resources are referred to by the hostname (and possibly subdomain).
This makes it fairly easy to have multiple projects in different subdomains
of a single domain - "dev", "test", and "prod", for instance. When applying
tags to resources, `ruby-awstools` uses the short qualified name for the
`Name` tag, and the FQDN for the `FQDN` tag, for disambiguating among
multiple projects. A consequence of this is that all resources of a given
type (instances, volumes, snapshots, etc.) must have a unique FQDN - though
you may have, e.g., an instance and a volume with the same FQDN.

A cloudconfig.yaml file should specify three DNS domain names, without a
leading or trailing dot:
* DNSBase: The DNS domain name of the AWS hosted zone, common across multiple
  projects, e.g. `mycompany.com`.
* DNSDomain: The DNS domain for all resources in a particular project, e.g.
  `dev.mycompany.com`.

Thus, whenever a name is provided, it will canonicalized and a FQDN generated
based on the configured domains. Some examples should make this clear:

When DNSDomain is `foo.com` and DNSBase is `foo.com`, 
the name is translated to a canonical name and fqdn as
follows:
* `bar` -> `bar`, `bar.foo.com`
* `bar.baz` -> `bar.baz`, `bar.baz.foo.com`
* `bar.foo.com` -> `bar`, `bar.foo.com`

When DNSDomain is `dev.foo.com`:
* `bar` -> `bar.dev`, `bar.dev.foo.com`
* `bar.dev` -> `bar.dev`, `bar.dev.foo.com`

#### Standard Parameters and Normalization

The library provides a `normalize_name_parameters` function that performs
DNS name canonicalization and checks/fixes the following standard parameters:
* name (instance or DNS record name)
* cname
* volname
* snapname
* az (uppercase availability zone, letter only, e.g. 'A')
* availability\_zone (library created parameter = lowercase region + az)

For `name` and `cname`, the function also creates and populates parameter
values for `fqdn` and `cfqdn` for a`cname` parameter.

### Template String Expansion

`ruby-awstools` is heavily template based, reading in YAML data structures
which get processed and used in AWS method calls. After reading in a template,
but before parsing the YAML, string replacement is done on variables of the
form ${...}.

* ${&var} - retrieve a string from the cloud config file, may optionally be
  indexed with \[key\]([subkey])...; throws an exception if the reference value
  isn't a string.
* ${@param(|<default>)} - use the value of a parameter obtained from the command line
  or interactively, or use the default value if the parameter is undefined.
  If <default> is of the form `$var`, the value is taken from the cloud config
  similarly to ${&var} above.
* ${=Template(:child):Output(|default)} - retrieve an output from a previously-created
  cloudformation template, or use the default value if the lookup fails.
* ${%item:key|default} - Look up the attribute <key> for <item> in the configured
  ConfigDB (AWS SimpleDB) from the cloud config. Mostly useful for retrieving
  AMI ids stored with the `sdb` tool.

### Data Element Expansion

After parsing the YAML into a data structure, `ruby-awstools` walks the
tree and looks for right-hand-side string elements of the form `$var`/`$@param`.
This allows you to replace array elements and hash values with arbitrarily
complex data structures from the cloud config file or generated parameter
structures; e.g. an array of hashes. As with other vars, \[key\]([subkey])...`
can be used to index into a structure.

* $var - look up data structure in the cloud config file.
* $@param - look up complex parameter; this must be created and set by the
  tool and is only for special cases such as TXT records, where the string
  value must be split into an array of 255-char substrings.
* $%item:key - look up value(s) from a SimpleDB domain, defaulting to the
  value of ConfigDB in the cloud config file.

### Context Specific Expansion

Individual tools like `cfn` will perform context specific expansion of
certain elements of the form $$var, and these will documented with the
individual tool
* $$Network - Context-specific expansion; individual tools interpret
  these in a service-specific fashion (e.g. see `cfn`, below)

# cfn - CloudFormation template generator and management

## Background
`cfn` started from the simple idea that writing CloudFormation templates
in YAML and trivially converting them to JSON was more convenient than
hand-writing JSON. Ruby can do this trivially, but that led to another idea:
as long as we're loading YAML into a data structure, why not perform some
(relatively) simple processing, to:
- Centralize configuration into a single file (as much as possible)
- Reduce the amount of hand-editing of templates
- Use automatic generation of things like Outputs, Parameters and tags to
make templates more robust and less error-prone

At the same time, using the aws ruby sdk, we can also handle validating,
creating, updating and deleting stacks, taking care of S3 URLs and vastly
simplifying the process of creating modular stacks.

## Description
`cfn` is the tool for generating CloudFormation(CF) templates and
creating/updating CF stacks. It is designed around a project directory
structure that consists of a `cloudconfig.yaml` with site-specific
configuration such as lists of users, subnets, CIDRs, S3 bucket name
and prefix, etc. Sub-directories contain yaml-formatted templates
that are read and processed by the `cfn` tool to generate more complicated
sets of CF JSON templates, by expanding and modifying the yaml
templates based on data in `cloudconfig.yaml`. For example, you can
provide a list of CIDRs used by your organization, and when the template
processor sees `Ref: $OrgCIDRs`, it will do a smart expansion based
on the type of resource being processed.

`ruby-awstools` comes with a `sample/` project directory that you can copy
to your own project. The intention is that a project will encapsulate
your AWS CF stacks and configuration, and be managed in an internal
repository, similar to what might be done with with `puppet` or `ansible`.

## Features
* Simpler Tags specification; { foo: bar } vs. { Key: foo, Value: bar } (can
be mixed)
* Variable expansion to get values from global config, cloudformation outputs,
etc.
* $$CidrList will perform intelligent expansion of lists of CIDRs
provided in cloudconfig.yaml; see **Resource Processing**

## Conventions
To enable intelligent processing and automatic generation, `cfn` uses certain
naming conventions in template files:
* Stack resources all have names like **<Something>Stack**, e.g.
  **SecurityGroupsStack**
* Names of Outputs are the same as the name of the resource they reference,
  except in special cases where a single resource generates multiple related
  outputs

## Directory Structure

`cfn` has features that make it easier to break large stacks out into
individual files that are easier to read and maintain. An individual stack
will always have a `main.yaml` for the main stack, and optionally other
`<stackname>.yaml` files that are child resources of `main.yaml`.

The directory structure for `cfn` looks like this:
```
cloudconfig.yaml - project-wide settings
	cfn/
		<stackname>/ - `cfn` creates a stack named after the subdirectory,
		  prefixed with `StackPrefix` if it's set in cloudconfig.yaml.
			main.yaml - the list of resources for this stack, may include
			  other stacks with resource names of <Something>Stack
			something.yaml - When main.yaml includes a <Something>Stack
			  resource, `cfn` gets the resources from `<something>.yaml`
			somethingelse.yaml
			...
		<stackname>/
		...
```

## Walk-through: creating a VPC+
This section will walk you through getting started with creating a general-purpose
VPC from the sample project.

**TODO** Write this

## Resource Processing and $$Variable Expansion
This section details the special handling of each of the CF resource types.

### AWS::CloudFormation::Stack

If you specify e.g.:
```
Parameters:
	Includes: [ SecurityGroups, VPC ]
```
... cfn will automatically pass all the outputs from the given stack(s) as
parameters to the stack.

An automatic Output will be created for the stack ID.

### AWS::EC2::RouteTable

An automatic Output will be created for the Route Table ID.

### AWS::RDS::DBInstance

Automatic Outputs will be generated for the Instance Identifier, Enpoint Address,
and TCP Port.

### AWS::RDS::DBSubnetGroup
If you specify:
```
SubnetIds: $$<SubnetName>
```
... where <SubnetName> is e.g. `PrivateSubnet`, cfn will automatically
expand to a list of references to the subnets in all availability zones.

An automatic Output will also be added for the name of the DBSubnetGroup.

### AWS::IAM::Role, AWS::IAM::InstanceProfile

An automatic Output will be added for the ARN.

## Network Structure from the sample project
One of the templates created by CG is the network template,
which defines the VPC and it's associated subnets, along with network
ACLs that put high-level restrictions on the network traffic to and
from the instances running in those subnets.

The VPC itself will reside in a single AWS region, but CG will duplicate
subnet types across a provided list of availability zones in the region.

## Subnet Types

### Public Subnets
Instances on public subnets will get Internet addresses, and can provide
services to the Internet as allowed by the specific Security Groups
assigned to launched instances.

The most likely type of instance on a Public subnets is a webserver, but
may potentially include other types of Internet-available service.

### Private Subnets
Instances on private subnets will not get Internet addresses, and can only
be reached by instances within the VPC. Access to the outside world is only
available via a NAT instance on the Management Subnet (see below).

The most likely types of instances on a private subnet are database,
LDAP, or configuration servers (puppet masters, Ansible-pull repositories).

### Intranet Subnets
Similar to Public subnets, but only reachable from provided address ranges.
Servers here are more likely to provide, e.g., login services via ssh or rdp.

### Management Subnets
The management subnets are for hosts that are used to manage other instances.
They can not be reached directly from the Internet, but have Internet
addresses and can connect to the outside world and can connect to login ports
on hosts in other subnets.

The types of instances launched here would be bastion hosts, hosts for
pushing configuration like 'Ansible', NAT instances, or possibly running e.g.
Jenkins.

## Configuration and Naming
For this section you should refer to the provided 'sampleconfig.yaml' for
and example configuration (which you may choose to use as-is).

You will need to determine the address space to use for your network, likely
a Class-B from somewhere in RFC 1918. You will also need to determine the
Availability Zones available to your account in the region where you'll create
your network; for this you can use `aws ec2 describe-availability-zones`.

From the possible Availability Zones, you'll select the ones you want to use
for your network - most likely all of them. For each Subnet Type, you'll
specify:
* A single CIDR encompassing all the subnets for the SubnetType
* A list of subnet CIDRs, one for each availability zone

For each subnet type, e.g. "Public", CG will create subnets corresponding
to the availability zones, e.g. "PublicA", "PublicB", etc.
