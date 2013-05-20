#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <spawn.h>
#include <errno.h>

#import "NSTask+Execute.h"


/* we support only one running NSTask */
static pid_t pid = 0;
static int status = 0;

static void prepareExecute(NSTask *self, const char **c_path, const char ***c_arguments, const char ***c_environment);


@implementation NSTask (Execute)

- (void)execute
{
	const char *c_path = NULL;
	const char **c_arguments = NULL;
	const char **c_environment = NULL;
	
	@try {
		prepareExecute(self, &c_path, &c_arguments, &c_environment);
		
		execve(c_path, (char **)c_arguments, (char **)c_environment);
		
		NSLog(@"error %d executing program “%s”", errno, c_path);
	}
	@finally {
		free(c_arguments);
		free(c_environment);
	}
}

- (void)simpleLaunch
{
	if (pid != 0) {
		NSLog(@"running multiple NSTasks concurrently is not supported");
		NSLog(@"to fix this, extend the Execute category in " __FILE__);
		abort();
	}
	
	const char *c_path = NULL;
	const char **c_arguments = NULL;
	const char **c_environment = NULL;
	
	@try {
		int saved_working_dir = open(".", O_RDONLY);
		
		prepareExecute(self, &c_path, &c_arguments, &c_environment);
		
		if (posix_spawn(&pid, c_path, NULL, NULL, (char **)c_arguments, (char **)c_environment) != 0)
			NSLog(@"error %d spawning child process “%s”", errno, c_path);
		
		if (saved_working_dir >= 0) {
			fchdir(saved_working_dir);
			close(saved_working_dir);
		}
	}
	@finally {
		free(c_arguments);
		free(c_environment);
	}
}

- (void)simpleWaitUntilExit
{
	if (pid == 0) {
		NSLog(@"no running NSTask to wait for");
	} else {
		int result;
		do {
			result = waitpid(pid, &status, 0);
		} while ((result < 0 && errno == EINTR) || result == 0 ||
				 (result == pid && !WIFEXITED(status) && !WIFSIGNALED(status)));
		pid = 0;
	}
}

- (void)simpleWaitUntilExitWithRunLoopMode:(NSString *)mode
{
	if (pid == 0) {
		NSLog(@"no running NSTask to wait for");
	} else {
		int result;
		do {
			[[NSRunLoop currentRunLoop] runMode:mode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
			result = waitpid(pid, &status, WNOHANG);
		} while ((result < 0 && errno == EINTR) || result == 0 ||
				 (result == pid && !WIFEXITED(status) && !WIFSIGNALED(status)));
		pid = 0;
	}
}

- (int)simpleTerminationStatus
{
	if (pid != 0)
		@throw NSInvalidArgumentException;
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	return status;
}

@end


static void prepareExecute(NSTask *self, const char **c_path, const char ***c_arguments, const char ***c_environment)
{
	NSString *currentDirectoryPath = [self currentDirectoryPath];
	NSString *launchPath = [self launchPath];
	NSArray *arguments = [self arguments];
	NSDictionary *environment = [self environment];
	
	*c_path = [launchPath cStringUsingEncoding:[NSString defaultCStringEncoding]];
	if (!*c_path)
		@throw NSInvalidArgumentException;
	
	if (currentDirectoryPath)
		chdir([currentDirectoryPath cStringUsingEncoding:[NSString defaultCStringEncoding]]);
	
	size_t i = 0;
	*c_arguments = malloc(([arguments count] + 2)  * sizeof(const char *));
	if (!*c_arguments)
		@throw NSInternalInconsistencyException;
	(*c_arguments)[i++] = [launchPath cStringUsingEncoding:[NSString defaultCStringEncoding]];
	for (NSString *argument in arguments)
		(*c_arguments)[i++] = [argument cStringUsingEncoding:[NSString defaultCStringEncoding]];
	(*c_arguments)[i] = NULL;
	
	if (!environment)
		environment = [[NSProcessInfo processInfo] environment];
	
	i = 0;
	*c_environment = malloc(([environment count] + 1) * sizeof(const char *));
	if (!*c_environment)
		@throw NSInternalInconsistencyException;
	NSString *environmentVariable;
	NSEnumerator *enumerator = [environment keyEnumerator];
	while ((environmentVariable = [enumerator nextObject])) {
		NSString *environmentValue = [environment objectForKey:environmentVariable];
		NSString *environmentPair = [NSString stringWithFormat:@"%@=%@", environmentVariable, environmentValue];
		(*c_environment)[i++] = [environmentPair cStringUsingEncoding:[NSString defaultCStringEncoding]];
	}
	(*c_environment)[i] = NULL;
}
