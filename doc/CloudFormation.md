This document describes the use of the `cfn` script, and the data directories it uses.

## Directory Structure

CloudFormation templates are stored under cfn/<stack directory>. That directory should contain a YAML or JSON file for each template in the stack, and a `stackconfig.yaml` that defines tags, parameters, stack name, etc. When `cfn` runs, it will create a subdirectory from the stack name, and write out all the templates used and the `stackconfig.yaml` file with all variables resolved.

## Template Loading

When `cfn` loads `stackconfig.yaml`, it first looks for `cfn/<stack directory>/stackconfig.yaml` in each directory in the search path, then the local repository version, merging and overwriting values along the way so that more specific values override defaults. When loading templates, the local repository is checked first, then backwards through the search path, using the first found. The actual template used is written out to `cfn/<stack directory>/<stack name>`.

## The Stack Config File

The `stackconfig.yaml` file stores the configuration for the CloudFormation stack, with the following format:
```yaml
# The filename of the main template
MainTemplate: main.yaml
# The name of the stack to create, variable expansion OK
StackName: Bootstrap
S3URL: https://s3.amazonaws.com # default value if not supplied
DisableUpload: true # should be specified for the CloudFormation bucket
# Stack parameters; variable expansion is the norm
Parameters:
# Stacks that create additional stacks should use the cfns3prefix generated parameter with e.g. "!Sub ${pcfns3prefix}/<template file name>"
    pcfns3prefix: ${@s3urlprefix}
#
ChildStacks:
- child1.yaml
- child2.json
```