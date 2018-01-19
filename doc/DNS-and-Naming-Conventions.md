TODO: re-read and update content transferred from README.md

## DNS Zones, Naming, and DNS Parameters

For simplicity, `ruby-awstools` design uses DNS-based naming conventions
where resources are referred to by the hostname (and possibly subdomain).
This makes it fairly easy to have multiple projects in different subdomains
of a single domain - "dev", "test", and "prod", for instance. When applying
tags to resources, `ruby-awstools` uses the short qualified name for the
`Name` tag. A consequence of this is that all resources of a given
type (instances, volumes, snapshots, etc.) must have a unique name - though
you may have, e.g., an instance and a volume with the same name (and the
volume is associated with the instance).

A cloudconfig.yaml file should specify three DNS domain names, without a
leading or trailing dot:
* DNSBase: The DNS domain name of the AWS hosted zone, common across multiple
  projects, e.g. `mycompany.com`.
* DNSDomain: The DNS domain for all resources in a particular project, e.g.
  `dev.mycompany.com`.

Thus, whenever a name is provided, it will be canonicalized and a FQDN generated
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

## Standard Parameters and Normalization

The library provides a `normalize_name_parameters` function that performs
DNS name canonicalization and checks/fixes the following standard parameters:
* name (instance or DNS record name)
* cname
* volname

For `name` and `cname`, the function also creates and populates parameter
values for `fqdn` and `cfqdn` for a`cname` parameter.
