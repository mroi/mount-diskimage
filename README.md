Auto-Mount Disk Images
======================

MacOS disk images are helpful if you want to create a sub-file system with different case 
sensitivity or crypto options, or if you want to store large files in a 
Time-Machine-friendly way. I use a disk image to store my VMware files, because they are 
huge and receive relatively small changes when the VM runs. When wrapped in a sparse bundle 
image, Time Machine gets those changes served in much smaller portions, which conserves 
backup space.

However, to provide a seamless experience, those kinds of disk images should not need user 
management, so auto-mounting is needed. MacOS already supports auto-mounting, but only for 
device-backed file systems. This project adds support for disk image auto-mounting.

To use it, install `mount_diskimage` to `/sbin`. Then add this line to the end of 
`/etc/auto_master`:

	/-	auto_image

You then add a new file `/etc/auto_image` listing your auto-mounted disk images on 
individual lines like this:

	/Users/Michael/Library/VMware/VMs	-fstype=diskimage :/Users/Michael/Library/VMware/VMs.sparsebundle

This work is licensed under the [WTFPL](http://www.wtfpl.net/), so you can do anything you 
want with it.
