#!/bin/sh

while [[ $# -gt 0 ]]; do
  case ${1} in
    -v|--version)
      VERSION="${2}"
      shift # past argument
      shift # past value
      ;;
    -a|--all-platforms)
      ALL_PLATFORMS="1"
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option ${1}"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("${1}") # save positional arg
      shift # past argument
      ;;
  esac
done

function get_ytdlp_name() {
	local PLATFORM=${1}
	local FILENAME=yt-dlp
	case "${PLATFORM}" in
		"windows")   FILENAME=${FILENAME}.exe;;
		"macos")     FILENAME=${FILENAME}_macos;;
		*);;
	esac
	echo ${FILENAME}
}

function download_yt_dlp() {
	local PLATFORM=${1}
	local FILENAME="$(get_ytdlp_name ${PLATFORM})"
	if [ ! -f Bin/${YT_VERSION}/${FILENAME} ]; then
		wget https://github.com/yt-dlp/yt-dlp/releases/download/${YT_VERSION}/${FILENAME} -P Bin/${YT_VERSION}
		if [ "${PLATFORM}" != "windows" ]; then
			chmod +x Bin/${YT_VERSION}/${FILENAME}
		fi
	fi
	rm -f Bin/yt-dlp*
	if [ "${PLATFORM}" == "windows" ]; then EXTENSION=.exe; fi
	cp Bin/${YT_VERSION}/${FILENAME} Bin/yt-dlp${EXTENSION}

}

function generate_zip() {
	local PLATFORM=${1}
	local ZIPFILE=lms_mixcloud-$VERSION-${PLATFORM}.zip
	echo "Creating ${ZIPFILE}..."
	download_yt_dlp ${PLATFORM}
	rm -f ${ZIPFILE}
	zip -r ${ZIPFILE} . -x \*.zip \*.sh \*.git\* \*README\* \*sublime-\* \*.DS_Store\* \*.template.xml yt-dlp\.version Bin/\.gitkeep Bin/*/\*
}

if [ -z ${VERSION} ]; then
	VERSION=`git describe --tags --abbrev=0`.`git rev-list $(git describe --tags --abbrev=0)..HEAD --count`-local
fi
YT_VERSION=`cat yt-dlp.version`

sed "s/{{ env\['VERSION'\] }}/$VERSION/g" install.template.xml > install.xml

generate_zip "linux"
if [ ! -z ${ALL_PLATFORMS} ]; then
	generate_zip "macos"
	generate_zip "windows"
fi

rm Bin/yt-dlp*
rm install.xml