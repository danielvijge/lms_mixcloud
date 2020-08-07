#!/bin/sh
set -x

VERSION=`git describe --tags`

sed "s/{{ env\['VERSION'\] }}/$VERSION/g" install.template.xml  > install.xml
zip -r lms_mixcloud-$VERSION.zip . -x \*.zip \*.sh \*.git\* \*README\* \*sublime-\* \*.DS_Store\* \*.template.xml
rm install.xml