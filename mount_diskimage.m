/* This executable will be run by automountd to handle 'diskimage' type mounts.
 * Apart from mount options, which we ignore completely, the relevant arguments
 * are the disk image to mount and the target mountpoint.
 * Automountd will have prepared the mountpoint and will run this executable
 * as the user requesting the mount. */

#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <spawn.h>
#include <time.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <errno.h>


/* start helper executable using standard fork()/exec() */
static int forkexec(NSString *executablePath, NSArray *arguments)
{
	pid_t pid = 0;
	
	const char *c_path = NULL;
	const char **c_arguments = NULL;
	const char **c_environment = NULL;
	
	@try {
		c_path = [executablePath cStringUsingEncoding:[NSString defaultCStringEncoding]];
		if (!c_path)
			@throw NSInvalidArgumentException;
		
		size_t i = 0;
		c_arguments = malloc(([arguments count] + 2)  * sizeof(const char *));
		if (!c_arguments)
			@throw NSInternalInconsistencyException;
		c_arguments[i++] = [executablePath cStringUsingEncoding:[NSString defaultCStringEncoding]];
		for (NSString *argument in arguments)
			c_arguments[i++] = [argument cStringUsingEncoding:[NSString defaultCStringEncoding]];
		c_arguments[i] = NULL;
		
		NSDictionary *environment = [[NSProcessInfo processInfo] environment];
		
		i = 0;
		c_environment = malloc(([environment count] + 1) * sizeof(const char *));
		if (!c_environment)
			@throw NSInternalInconsistencyException;
		NSString *environmentVariable;
		NSEnumerator *enumerator = [environment keyEnumerator];
		while ((environmentVariable = [enumerator nextObject])) {
			NSString *environmentValue = [environment objectForKey:environmentVariable];
			NSString *environmentPair = [NSString stringWithFormat:@"%@=%@", environmentVariable, environmentValue];
			c_environment[i++] = [environmentPair cStringUsingEncoding:[NSString defaultCStringEncoding]];
		}
		c_environment[i] = NULL;
		
		if (posix_spawn(&pid, c_path, NULL, NULL, (char **)c_arguments, (char **)c_environment) != 0)
			NSLog(@"error %d spawning child process “%s”", errno, c_path);
	}
	@finally {
		free(c_arguments);
		free(c_environment);
	}
	
	int result, status = 0;
	do {
		result = waitpid(pid, &status, 0);
	} while ((result < 0 && errno == EINTR) || result == 0 ||
			 (result == pid && !WIFEXITED(status) && !WIFSIGNALED(status)));
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	return status;
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
		lock = open([lockfile fileSystemRepresentation], O_CREAT | O_RDWR | O_EXLOCK, S_IRUSR | S_IWUSR);
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
		srandom(time(NULL));
		if (random() / (float)RAND_MAX < 0.1) {
			status = forkexec(@"/usr/bin/hdiutil", [NSArray arrayWithObjects:@"compact", image, nil]);
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
		status = forkexec(@"/bin/sh", [NSArray arrayWithObjects:@"-c", shellCommand, nil]);
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
			if ([[attachItem objectForKey:@"potentially-mountable"] boolValue] &&
				(disk = [attachItem objectForKey:@"dev-entry"]))
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
