Gem::Specification.new do |s|
	s.name = 'rawstools'
	s.version = '0.1.1'
	s.date = '2016-10-11'
	s.summary = 'Ruby AWSTools'
	s.description = 'Tools for managing a cloud of AWS instances and resources'
	s.authors = ["David Parsley"]
	s.email = 'dlp7y@virginia.edu'
	s.homepage = 'https://github.com/uva-its/ruby-awstools'
	s.license = 'MIT'
	s.files = Dir.glob("{bin,lib}/**/*") + %w(LICENSE README.md)
	s.executables = ['ec2', 'cfn', 'rds', 'r53', 'sdb']
	s.add_runtime_dependency "aws-sdk", "~> 2.9", ">= 2.9.10"
end
