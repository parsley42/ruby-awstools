# Overview

ruby-awstools consists of various ruby cli scripts using the Ruby aws-sdk, intended to:
* Simplify creation of AWS resources
* Manage sets of CloudFormation stacks
* Centralize configuration data with an aim towards "configuration as code"

Currently the only tool provided is `cfn`, for managing CloudFormation
stacks.

# Installation
1. Clone the repository
2. Make sure you have the ruby gem 'bundler' installed:
```
# gem install bundler
```
`bundler` is the tool used for vendoring the aws-sdk ruby gem and any dependent gems
3. 2. Then, in the top-level directory:
```
$ bundle install
```
This tells bundler to install the gems from vendor/cache to vendor/ruby
4. Create symlinks to scripts in the `bin/` directory of your choice; `/usr/local/bin` or `$HOME/bin` are both good choices.

# cfn - CloudFormation template generator and management

## Background
`cfn` started from the simple idea that writing CloudFormation templates
in YAML and trivially converting them to JSON was more convenient than
hand-writing JSON. Ruby can do this trivially, but that led to another idea:
as long as we're loading YAML into a data structure, why not perform some
(relatively) simple processing, to:
- Centralize configuration into a single file (as much as possible)
- Intelligently handle arrays of CIDRs depending on resources being generated
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

## Walk-through: creating a VPC+
This section will walk you through getting started with creating a general-purpose
VPC from the sample project.

**TODO** Write this

## Resource Processing
This section details the special handling of each of the CF resource types.

**TODO** write this

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
