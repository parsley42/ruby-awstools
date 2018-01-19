In the context of `ruby-awstools`, parameters are any values determined at runtime and available for expansion in a template using the `${@parameter}` syntax.

## Normalizing Parameters

When the user supplies a *name* parameter for an instance, volume, or other entity, `ruby-awstools` will automatically normalize the name in to the cononical format.

## Generated Parameters

`ruby-awstools` will automatically generate values for certain parameters, as documented here:

 * `userparameters` - The names and normalized values of all the user-specified parameters, "+" separated list of "<param>=<value>"
 * `repositories` - The scripts and configuration repositories in use starting with `ruby-awstools` and followed by the repositories in the SearchPath followed by the local repository, ':' separated list of <repo name up to 30 chars>@<commit 1st 8 chars><optional'+'>, up to 6 entries; the '+' indicates uncommitted changes
 * `creator` - The user running the script, auto-detected from `$USER` if not supplied
 * `s3urlprefix` - The prefix (https://s3.amazonaws.com/...) for child templates