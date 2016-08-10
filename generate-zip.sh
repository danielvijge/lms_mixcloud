#!/bin/sh
set -x

VERSION=$(grep \<version\> install.xml  | perl -n -e '/>(.*)</; print $1;')

cd ..
mv lms_mixcloud MixCloud
rm lms_mixcloud-$VERSION.zip
zip -r lms_mixcloud-$VERSION.zip MixCloud -x \*.zip \*.sh \*.git\* \*README\* \*sublime-\* \*.DS_Store\*
mv MixCloud lms_mixcloud
SHA=$(shasum lms_mixcloud-$VERSION.zip | awk '{print $1;}')

cat <<EOF > public.xml
<extensions>
	<details>
		<title lang="EN">Mixcloud Plugin</title>
	</details>
	<plugins>
		<plugin name="MixCloud" version="$VERSION" minTarget="7.5" maxTarget="*">
			<title lang="EN">Mixcloud</title>
			<desc lang="EN">Play music from Mixcloud</desc>
			<url>http://danielvijge.github.io/lms_mixcloud/lms_mixcloud-$VERSION.zip</url>
			<link>https://github.com/danielvijge/lms_mixcloud</link>
			<sha>$SHA</sha>
			<creator>Christian Mueller, Daniel Vijge</creator>
		</plugin>
	</plugins>
</extensions>
EOF
