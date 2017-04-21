#!/bin/bash

# publish.sh - copy the install archive to a distribution point

. .publish
VERSTRING=$(grep "s.version" rawstools.gemspec)
VERSTRING=${VERSTRING%\'}
VERSION=${VERSTRING#*\'}

SRCFILE=rawstools-$VERSION.gem
echo "Publishing $SRCFILE to $PREFIX/ruby-awstools/$VERSION/rawstools.gem"
aws s3 cp $SRCFILE $PREFIX/ruby-awstools/$VERSION/rawstools.gem
