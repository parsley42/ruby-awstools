#!/bin/bash

# publish.sh - copy the install archive to a distribution point

. .publish
VERSTRING=$(grep "s.version" rawstools.gemspec)
VERSTRING=${VERSTRING%\'}
VERSION=${VERSTRING#*\'}
MINVER=${VERSION%.*}
TVER=$(git describe --tags)
if [[ "$TVER" = *-*-* ]]
then
    PUBVER="$MINVER-dev"
else
    PUBVER="$MINVER"
fi

SRCFILE=rawstools-$VERSION.gem
echo "Publishing $SRCFILE to $PREFIX/ruby-awstools/$PUBVER/rawstools.gem"
exit 0
aws s3 cp $SRCFILE $PREFIX/ruby-awstools/$PUBVER/rawstools.gem
