# Overview

ruby-awstools consists of various tools to:
* Simplify creation of AWS resources
* Manage sets of CloudFormation stacks
* Centralize configuration data with an aim towards "configuration as code"

Currently the only tool provided is `cfn`, for managing CloudFormation
stacks.

NOTE: Everything below is somewhat out-of-date.

# cfn - CloudFormation template generator and management

`cfn` can be used for creating general-purpose AWS networks, with
a fairly generic structure intended to be useful for a wide-range of
applications. Your particular application may not use all features, but
since creating VPCs, subnets, buckets, etc. are all 'free' (you only pay
for actual resources used), it's handy to be able to edit a simple
configuration file that can be used to generate your network. This document
outlines the structure of the networks and resources generated, as well as
the configuration file and tool use.

CloudGenerator will use a cloudconfig.yaml and a set of pared-down
and commented CloudFormation templates in yaml format. From those it
will create a set of json templates that can be uploaded to S3.

# Network Structure

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
