Auto-Mount Disk Images
======================

MacOS disk images are helpful if you want to create a sub-file system with different case 
sensitivity options, or if you want to store large files in a Time-Machine-friendly way. I 
use a disk image to store my VMware files, because they are huge and receive relatively 
small changes when the VM runs. When wrapped in a sparse bundle image, Time Machine gets 
those changes served in much smaller portions, which conserves backup space.

However, to provide a seamless experience, those kinds of disk images should not need user 
management, so auto-mounting is needed. MacOS already supports auto-mounting, but only for 
device-backed file systems. This project adds support for disk image auto-mounting.

To use it, add `mount_diskimage` as an executable mount map to of `/etc/auto_master` similar 
to this (path names will vary for you):

	/System/Volumes/Data/images	/var/root/mount_diskimage	-hidefromfinder

Then run `automount -c` for changes to become effective. You can configure the diskimages to 
be automounted in the `imageMounts` variable right in the code. Sorry, no config file.

___
This work is licensed under the [WTFPL](http://www.wtfpl.net/), so you can do anything you 
want with it.
