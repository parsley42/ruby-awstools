#!/bin/bash
rm rawstools-*.gem
gem build rawstools.gemspec
gem install -N rawstools-*.gem
