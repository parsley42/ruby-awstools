`cfn` has features that make it easier to break large stacks out into
individual files that are easier to read and maintain. An individual stack
will always have a `main.yaml` for the main stack, and optionally other
`<stackname>.yaml` files that are child resources of `main.yaml`.

The directory structure for `cfn` looks like this:
```
cloudconfig.yaml - project-wide settings
	cfn/
		<stackdefinition>/ - `cfn` creates a stack named after the subdirectory,
		  prefixed with `StackPrefix` if it's set in cloudconfig.yaml.
			main.yaml - the list of resources for this stack, may include
			  other stacks with resource names of <Something>Stack
			something.yaml - When main.yaml includes a <Something>Stack
			  resource, `cfn` gets the resources from `<something>.yaml`
			somethingelse.yaml
			...
		<stackdefinition>/
		...
```