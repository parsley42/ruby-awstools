# bundler for ruby @ bundler.io

# FIRST: Add gems to Gemfile
# Store gem source in vendor/ruby subdirectory (put this in .gitignore)
bundle install --path vendor
# Store packaged gems in vendor/cache subdirectory (commit this in git)
bundle package
# NOW: Add Gemfile and Gemfile.lock to repository
# To install gems from cache without connecting to rubygems.org:
bundle install --local --path vendor
