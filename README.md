# Mixcloud Plugin for Logitech Squeezebox media server #

This is a Logitech Media Server (LMS) (a.k.a Squeezebox server) plugin to play
tracks from Mixcloud. To install, use the settings page of Logitech Media server.
Go to the _Plugins_ tab, scroll down to _Third party source_ and select _Mixcloud_.
Press the _Apply_ button and restart LMS.

After installation, you can configure the Plugin under _Settings_ > _Advanced_ > _Mixcloud_

The plugin is included as a default third party resource. It is distributed via my
[personal repository](https://server.vijge.net/squeezebox/) This third party repository
is synced with the repository XML files on GitHub. It is also possible to directly include
the repository XML from GitHub. For the release version, include
    
    https://danielvijge.github.io/lms_mixcloud/public.xml

For the development version (updated with every commit), include

    https://danielvijge.github.io/lms_mixcloud/public-dev.xml

This Plugin is in Alpha stage and build from the SqueezeCloud Plugin (thanks to the developers), because the documentation
of the LMS Server is very bad and Perl still sucks.

## Licence ##

This work is distributed under the GNU General Public License version 2. See file LICENSE for
full license details.
