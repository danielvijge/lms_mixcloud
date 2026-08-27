# Mixcloud Plugin for Lyrion Music Server #

This is a Lyrion Music Server (LMS) (a.k.a Squeezebox server) plugin to play tracks from Mixcloud.
It uses `ffmpeg` to transcode the Mixcloud stream.
To install, use the settings page of Lyrion Music server.
Go to the _Plugins_ tab, scroll down to _3rd party plugins_ and select Mixcloud.
Press the _Apply_ button and restart LMS.

After installation, you can configure the Plugin under _Settings_ > _Advanced_ > _Mixcloud_

The plugin is included as a default third party resource. It is retrieved from this
GitHub repository. It is also possible to directly include
the repository XML as an additional repository. For the release version, include

    https://danielvijge.github.io/lms_mixcloud/public.xml

For the development version (updated with every commit), include

    https://danielvijge.github.io/lms_mixcloud/public-dev.xml

Development builds are only available for Linux. Regular builds are released for Linux,
Windows, and MacOS.

## ffmpeg ##

`ffmpeg` must be installed to transcode the Mixcloud stream to a stream that can be played directly by LMS.
On Debian Linux this can be installed like this:

    sudo apt install ffmpeg

When using the official Docker image, refer to the documentation how to install `ffmpeg` every time a new version is pulled.

The type of transcoding can be configured via _Settings_ > _Advanced_ > _File Types_.
Available options are flac, pmc, or mp3. Transcoding to mp3 also requires `lame` to be installed.

## Running on the official LMS docker image

This plugin uses `yt-dlp` to retrieve a playable stream URL.
This does not work by default on the official docker image of LMS.
Trying to play a Mixcloud stream on LMS running on the official docker image gives an error message:

    /usr/bin/env: python3: No such file or directory

The official docker image does not contain `python3`, but python 3.10 is required by the bundled version of the helper application (`yt-dlp`).
See [this issue in the issue tracker](https://github.com/danielvijge/lms_mixcloud/issues/36) for suggested solutions.

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
