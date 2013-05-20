/* This executable will be run by automountd to handle 'diskimage' type mounts.
 * Apart from mount options, which we ignore completely, the relevant arguments
 * are the disk image to mount and the target mountpoint.
 * We run a helper script, which uses hdiutil to actually perform the mount.
 * Automountd will have prepared the mountpoint and will run this executable
 * as the user requesting the mount. */

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#import "NSTask+Execute.h"

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/errno.h>


/* Start helper executable using launch services, because it executes the helper
 * in the user’s bootstrap domain, where it has proper access to keychains. */
static int launch(const UInt8 *executablePath, CFArrayRef arguments)
{
	FSRef executable;
	if (FSPathMakeRef(executablePath, &executable, NULL) != 0) {
		NSLog(@"unable to locate %s", executablePath);
		return EPERM;
	}
	LSApplicationParameters launchParams = {
		.version =  0,
		.flags =  kLSLaunchDontAddToRecents | kLSLaunchDontSwitch | kLSLaunchNewInstance,
		.application =  &executable,
		.asyncLaunchRefCon = NULL,
		.environment = NULL,
		.argv =  arguments,
		.initialEvent = NULL
	};
	
	/* I hope the waiting for the launchee is not done in a run loop, as this
	 * would register with diskarbitrationd and deadlock asking for details on
	 * the mount we want to establish. */
	if (LSOpenApplication(&launchParams, NULL) != 0) {
		NSLog(@"error launching %s", executablePath);
		return EPERM;
	}
	
	return 0;
}

/* start helper executable using standard fork()/exec() */
static int forkexec(NSString *executablePath, NSArray *arguments)
{
	NSTask *helper = [[[NSTask alloc] init] autorelease];
	[helper setLaunchPath:executablePath];
	[helper setArguments:arguments];
	[helper setEnvironment:[NSDictionary dictionary]];
	[helper simpleLaunch];
	[helper simpleWaitUntilExit];
	return [helper simpleTerminationStatus];
}


int main(int argc, const char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSString *lockfile = [NSString stringWithFormat:@"/var/tmp/local.mount_diskimage.%d", getuid()];
	int lock = -1;
	
	@try {
		int status;
		
#ifndef DEBUG
		if (getegid() != 0) {
			NSLog(@"the diskimage mounter is supposed to be used by automountd only");
			return EPERM;
		}
#endif
		
		/* play it safe: prevent concurrent execution of automounts */
		lock = open([lockfile fileSystemRepresentation], O_CREAT | O_RDWR | O_EXLOCK);
		if (lock < 0) {
			NSLog(@"failed to acquire lock");
			return EPERM;
		}
		
		/* parse command line arguments */
		BOOL skipNext = YES;
		NSString *image = nil;
		NSString *mountpoint = nil;
		for (NSString *argument in [[NSProcessInfo processInfo] arguments]) {
			if (skipNext)
				skipNext = NO;
			else if ([argument isEqualToString:@"-o"])
				skipNext = YES;
			else if (!image)
				image = argument;
			else if (!mountpoint)
				mountpoint = argument;
			else {
				NSLog(@"error parsing argument list: too many arguments");
				return EPERM;
			}
		}
		if (!image || !mountpoint) {
			NSLog(@"error parsing argument list: too few arguments");
			return EPERM;
		}
		
		/* We cannot use NSFileManager APIs here as they call out to an external
		 * service, which enumerates all mounts and thus deadlocks on the mount
		 * we try to establish. */
		struct stat statbuf;
		if (stat([image fileSystemRepresentation], &statbuf) != 0) {
			NSLog(@"no disk image found at ‘%@’", image);
			return EPERM;
		}
		if (statbuf.st_uid != getuid())
			return EPERM;
		
		/* compact the disk image for about 10% of mount attempts */
		srand(time(NULL));
		if ((float)rand() / (float)RAND_MAX < 0.1) {
			status = launch((const UInt8 *)"/usr/bin/hdiutil", (CFArrayRef)[NSArray arrayWithObjects:@"compact", image, nil]);
			if (status != 0)
				NSLog(@"compaction failed for disk image ‘%@’", image);
			else
				NSLog(@"compacted disk image ‘%@’", image);
		}
		
		/* Pre-attach the image without mounting it, because mounting would
		 * deadlock. Reason: hdiutil does not mount the image itself, but
		 * through DiskArbitration. This would cause the actual mount command to
		 * be executed by diskarbitrationd, which is then not a sub-process of
		 * automountd. The in-kernel autofs however will block all attempts to
		 * access the in-flight mount point until mount_diskimage returns.
		 * Only children and grand-children of automountd can proceed. Mounting
		 * through DiskArbitration subverts this and causes deadlock. */
		NSString *shellCommand = [NSString stringWithFormat:@"/usr/bin/hdiutil attach '%@' -nomount -noverify -noautofsck -plist > %@", image, lockfile];
		status = launch((const UInt8 *)"/bin/sh", (CFArrayRef)[NSArray arrayWithObjects:@"-c", shellCommand, nil]);
		if (status != 0) {
			NSLog(@"attaching the disk image ‘%@’ failed with error code %d", image, status);
			return EPERM;
		}
		
		/* parse plist output of hdiutil to determine disk device */
		NSDictionary *attachResult = [NSDictionary dictionaryWithContentsOfFile:lockfile];
		if (!attachResult) {
			NSLog(@"error reading the plist output of hdiutil attach");
			return EPERM;
		}
		NSString *disk = nil;
		for (NSDictionary *attachItem in [attachResult objectForKey:@"system-entities"])
			if ([[attachItem objectForKey:@"content-hint"] isEqualToString:@"Apple_HFS"] ||
				[[attachItem objectForKey:@"content-hint"] isEqualToString:@"Apple_HFSX"])
				if ((disk = [attachItem objectForKey:@"dev-entry"]))
					break;
		if (!disk) {
			NSLog(@"no mountable volume found in disk image ‘%@’", image);
			return EPERM;
		}
		
		/* check the filesystem and repair damage */
		status = forkexec(@"/sbin/fsck_hfs", [NSArray arrayWithObjects:@"-q", disk, nil]);
		if (status != 0) {
			NSLog(@"the file system in disk image ‘%@’ needs repair, error code: %d", image, status);
			status = forkexec(@"/usr/sbin/diskutil", [NSArray arrayWithObjects:@"repairDisk", disk, nil]);
			if (status != 0) {
				NSLog(@"the file system could not be repaired, error code: %d", status);
				return EPERM;
			}
		}
		
		/* mount the filesystem */
		status = forkexec(@"/sbin/mount", [NSArray arrayWithObjects:@"-t", @"hfs", @"-o", @"nodev,nosuid", disk, mountpoint, nil]);
		/* This magically publishes the new mount at DiskArbitration, and
		 * consequently, Spotlight indexing works. I think we are relying on an
		 * implementation detail here, hopefully this will never change… */
		if (status != 0) {
			NSLog(@"mounting the disk image ‘%@’ to directory ‘%@’ failed with error code %d", image, mountpoint, status);
			return EPERM;
		}
		
		return 0;
	}
	/* Automountd assumes that return values are always valid error codes.
	 * Since exceptions alter the return value, we catch everything and return
	 * something benign. */
	@catch (NSException *exception) {
		NSLog(@"caught exception %@: %@", [exception name], [exception reason]);
	}
	@catch (id) {
		NSLog(@"caught unknown exception");
	}
	@finally {
		if (lock >= 0) {
			flock(lock, LOCK_UN);
			close(lock);
		}
		unlink([lockfile fileSystemRepresentation]);
		
		[pool drain];
	}
	
	return EPERM;
}
