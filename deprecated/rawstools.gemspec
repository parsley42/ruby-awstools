Gem::Specification.new do |s|
  s.name = 'rawstools'
  s.version = '0.2.1'
  s.date = '2016-10-11'
  s.summary = 'Ruby AWSTools'
  s.description = 'Tools for managing a cloud of AWS instances and resources'
  s.authors = ["David Parsley"]
  s.email = 'dlp7y@virginia.edu'
  s.homepage = 'https://github.com/uva-its/ruby-awstools'
  s.license = 'MIT'
  s.files = Dir.glob("{bin,lib}/**/*") + %w(LICENSE README.md)
  s.executables = ['ec2', 'cfn', 'rds', 'r53', 'sdb']
  s.add_runtime_dependency "aws-sdk-ec2", "~> 1.22", ">= 1.22.0"
  s.add_runtime_dependency "aws-sdk-iam", "~> 1.3", ">= 1.3.0"
  s.add_runtime_dependency "aws-sdk-s3", "~> 1.8", ">= 1.8.0"
  s.add_runtime_dependency "aws-sdk-cloudformation", "~> 1.3", ">= 1.3.0"
  s.add_runtime_dependency "aws-sdk-rds", "~> 1.8", ">= 1.8.0"
  s.add_runtime_dependency "aws-sdk-simpledb", "~> 1.0", ">= 1.0.0"
  s.add_runtime_dependency "aws-sdk-route53", "~> 1.5", ">= 1.5.0"
end
