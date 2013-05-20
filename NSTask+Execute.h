#import <Foundation/NSTask.h>


@interface NSTask (Execute)

/* other than -launch, this does not fork and only execs */
- (void)execute;

/* The original -waitUntilExit waits inside a run loop and will set one up, if
 * the current application has none. This will spawn helper threads and register
 * for a couple of callbacks. If you do not want that and require only a very
 * lightweight fork/exec/wait task, where you fully understand what's happening,
 * then use the methods below. This will also enable -execute to work
 * afterwards. Otherwise, the run loop helper threads cause any later execve()
 * to fail, because Darwin does not allow execve() in a process with more than
 * one thread.
 * Big fat warning: We do not support multiple concurrent NSTasks running. */
- (void)simpleLaunch;
- (void)simpleWaitUntilExit;
- (int)simpleTerminationStatus;

/* This -waitUntilExit variant is a little less simple. It oscillates (with sane
 * frequency) between probing the child using nonblocking wait and probing the
 * current run loop with the given mode.
 * This is helpful, if you need to wait for a child and process some run loop
 * events at the same time and within the same thread. Using the original
 * -waitUntilExit does not allow you to specify the mode and creates helper
 * threads, causing all kinds of complaints along the lines of EXC_CRASH:
 * "multi-threaded process forked". */
- (void)simpleWaitUntilExitWithRunLoopMode:(NSString *)mode;

@end
