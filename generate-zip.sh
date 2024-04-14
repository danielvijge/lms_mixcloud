#!/bin/sh
set -x

VERSION=`git describe --tags --abbrev=0`.`git rev-list $(git describe --tags --abbrev=0)..HEAD --count`

sed "s/{{ env\['VERSION'\] }}/$VERSION/g" install.template.xml  > install.xml

YT_VERSION=`cat yt-dlp.version`

rm Bin/yt*
wget https://github.com/yt-dlp/yt-dlp/releases/download/${YT_VERSION}/yt-dlp -P Bin && chmod +x Bin/yt-dlp
zip -r lms_mixcloud-$VERSION-linux.zip . -x \*.zip \*.sh \*.git\* \*README\* \*sublime-\* \*.DS_Store\* \*.template.xml Bin\.gitkee

rm Bin/yt*
wget https://github.com/yt-dlp/yt-dlp/releases/download/${YT_VERSION}/yt-dlp.exe -P Bin
zip -r lms_mixcloud-$VERSION-windows.zip . -x \*.zip \*.sh \*.git\* \*README\* \*sublime-\* \*.DS_Store\* \*.template.xml Bin\.gitkeep Bin\yt-dlp

rm Bin/yt*
wget https://github.com/yt-dlp/yt-dlp/releases/download/${YT_VERSION}/yt-dlp_macos -P Bin && chmod +x Bin/yt-dlp_macos
mv Bin/yt-dlp_macos Bin/yt-dlp
zip -r lms_mixcloud-$VERSION-macos.zip . -x \*.zip \*.sh \*.git\* \*README\* \*sublime-\* \*.DS_Store\* \*.template.xml Bin\.gitkeep Bin\yt-dlp.exe

rm install.xml