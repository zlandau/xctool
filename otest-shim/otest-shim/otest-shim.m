//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/uio.h>

#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/errno.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/wait.h>

#import <Foundation/Foundation.h>
#import <SenTestingKit/SenTestingKit.h>

#import "../../xctool/xctool/Reporter.h"

#import "dyld-interposing.h"
#import "dyld_priv.h"

#define READ_SIDE 0
#define WRITE_SIDE 1

static int __eventPipeFds[2] = {0};
static FILE *__eventPipeWriteSide = NULL;

#define ARRAYSIZE(arr) (sizeof(arr) / sizeof(arr[0]))

static BOOL __testIsRunning = NO;
static NSException *__testException = nil;
static NSMutableString *__testOutput = nil;

static void SwizzleClassSelectorForFunction(Class cls, SEL sel, IMP newImp)
{
  Class clscls = object_getClass((id)cls);
  Method originalMethod = class_getClassMethod(cls, sel);

  NSString *selectorName = [NSString stringWithFormat:@"__%s_%s", class_getName(cls), sel_getName(sel)];
  SEL newSelector = sel_registerName([selectorName cStringUsingEncoding:[NSString defaultCStringEncoding]]);

  class_addMethod(clscls, newSelector, newImp, method_getTypeEncoding(originalMethod));
  Method replacedMethod = class_getClassMethod(cls, newSelector);
  method_exchangeImplementations(originalMethod, replacedMethod);
}

static void PrintJSON(id JSONObject)
{
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:JSONObject options:0 error:&error];

  if (error) {
    fprintf(stderr,
            "ERROR: Error generating JSON for object: %s: %s\n",
            [[JSONObject description] UTF8String],
            [[error localizedFailureReason] UTF8String]);
    exit(1);
  }

//  NSString *str = [[[NSString alloc] initWithData:data
//                                         encoding:NSUTF8StringEncoding] autorelease];
//  NSLog(@"write %@ >>>", str);

  // Send length of data, then data.
  uint32_t dataLen = (uint32_t)[data length];
//  fwrite(&dataLen, 4, 1, __eventPipeWriteSide);
  fwrite([data bytes], dataLen, 1, __eventPipeWriteSide);
  fprintf(__eventPipeWriteSide, "\n");
  fflush(__eventPipeWriteSide);

//  write(__eventPipeFds[WRITE_SIDE], &dataLen, 4);
//  write(__eventPipeFds[WRITE_SIDE], [data bytes], dataLen);
}

static void SenTestLog_testSuiteDidStart(id self, SEL sel, NSNotification *notification)
{
  SenTestRun *run = [notification run];
  PrintJSON(@{
            @"event" : kReporter_Events_BeginTestSuite,
            kReporter_BeginTestSuite_SuiteKey : [[run test] description],
            });
}

static void SenTestLog_testSuiteDidStop(id self, SEL sel, NSNotification *notification)
{
  SenTestRun *run = [notification run];
  PrintJSON(@{
            @"event" : kReporter_Events_EndTestSuite,
            kReporter_EndTestSuite_SuiteKey : [[run test] description],
            kReporter_EndTestSuite_TestCaseCountKey : @([run testCaseCount]),
            kReporter_EndTestSuite_TotalFailureCountKey : @([run totalFailureCount]),
            kReporter_EndTestSuite_UnexpectedExceptionCountKey : @([run unexpectedExceptionCount]),
            kReporter_EndTestSuite_TestDurationKey: @([run testDuration]),
            kReporter_EndTestSuite_TotalDurationKey : @([run totalDuration]),
            });
}

static void SenTestLog_testCaseDidStart(id self, SEL sel, NSNotification *notification)
{
  SenTestRun *run = [notification run];
  PrintJSON(@{
            @"event" : kReporter_Events_BeginTest,
            kReporter_BeginTest_TestKey : [[run test] description],
            });

  [__testException release];
  __testException = nil;
  __testIsRunning = YES;
  __testOutput = [[NSMutableString string] retain];
}

static void SenTestLog_testCaseDidStop(id self, SEL sel, NSNotification *notification)
{
  SenTestRun *run = [notification run];
  NSMutableDictionary *json = [NSMutableDictionary dictionaryWithDictionary:@{
                               @"event" : kReporter_Events_EndTest,
                               kReporter_EndTest_TestKey : [[run test] description],
                               kReporter_EndTest_SucceededKey : [run hasSucceeded] ? [NSNumber numberWithBool:YES] : [NSNumber numberWithBool:NO],
                               kReporter_EndTest_TotalDurationKey : @([run totalDuration]),
                               kReporter_EndTest_OutputKey : __testOutput,
                               }];

  if (__testException != nil) {
    [json setObject:@{
     kReporter_EndTest_Exception_FilePathInProjectKey : [__testException filePathInProject],
     kReporter_EndTest_Exception_LineNumberKey : [__testException lineNumber],
     kReporter_EndTest_Exception_ReasonKey : [__testException reason],
     kReporter_EndTest_Exception_NameKey : [__testException name],
     }
             forKey:kReporter_EndTest_ExceptionKey];
  }

  PrintJSON(json);

  __testIsRunning = NO;
  [__testOutput release];
  __testOutput = nil;
}

static void SenTestLog_testCaseDidFail(id self, SEL sel, NSNotification *notification)
{
  NSException *exception = [notification exception];
  if (__testException != exception) {
    [__testException release];
    __testException = [exception retain];
  }
}

static void SaveExitMode(NSDictionary *exitMode)
{
  NSDictionary *env = [[NSProcessInfo processInfo] environment];
  NSString *saveExitModeTo = [env objectForKey:@"SAVE_EXIT_MODE_TO"];

  if (saveExitModeTo) {
    assert([exitMode writeToFile:saveExitModeTo atomically:YES] == YES);
  }
}

static void __exit(int status)
{
  SaveExitMode(@{@"via" : @"exit", @"status" : @(status) });
  exit(status);
}
DYLD_INTERPOSE(__exit, exit);

static void __abort()
{
  SaveExitMode(@{@"via" : @"abort"});
  abort();
}
DYLD_INTERPOSE(__abort, abort);


static const char *DyldImageStateChangeHandler(enum dyld_image_states state,
                                               uint32_t infoCount,
                                               const struct dyld_image_info info[])
{
  for (uint32_t i = 0; i < infoCount; i++) {
    // Sometimes the image path will be something like...
    //   '.../SenTestingKit.framework/SenTestingKit'
    // Other times it could be...
    //   '.../SenTestingKit.framework/Versions/A/SenTestingKit'
    if (strstr(info[i].imageFilePath, "SenTestingKit.framework") != NULL) {
      // Since the 'SenTestLog' class now exists, we can swizzle it!
      SwizzleClassSelectorForFunction(NSClassFromString(@"SenTestLog"),
                                      @selector(testSuiteDidStart:),
                                      (IMP)SenTestLog_testSuiteDidStart);
      SwizzleClassSelectorForFunction(NSClassFromString(@"SenTestLog"),
                                      @selector(testSuiteDidStop:),
                                      (IMP)SenTestLog_testSuiteDidStop);
      SwizzleClassSelectorForFunction(NSClassFromString(@"SenTestLog"),
                                      @selector(testCaseDidStart:),
                                      (IMP)SenTestLog_testCaseDidStart);
      SwizzleClassSelectorForFunction(NSClassFromString(@"SenTestLog"),
                                      @selector(testCaseDidStop:),
                                      (IMP)SenTestLog_testCaseDidStop);
      SwizzleClassSelectorForFunction(NSClassFromString(@"SenTestLog"),
                                      @selector(testCaseDidFail:),
                                      (IMP)SenTestLog_testCaseDidFail);
    }
  }

  return NULL;
}

static void ReadAndEchoEvent(int fd)
{
  NSLog(@"here0");
  uint32_t eventLength = 0;
  size_t eventLengthRead = read(fd, &eventLength, 4);
  NSCAssert(eventLengthRead == 4,
            @"read() returned %lu: %s",
            eventLengthRead,
            (eventLengthRead == -1) ? strerror(errno) : "");

  void *eventData = malloc(eventLength);
  NSCAssert(eventData != NULL, @"malloc() failed: %s", strerror(errno));

  NSLog(@"here2");
  size_t eventDataRead = read(fd, eventData, eventLength);
  NSCAssert(eventDataRead == eventLength,
            @"read() returned %lu (expected %u): %s",
            eventDataRead,
            eventLength,
            (eventDataRead == -1) ? strerror(errno) : "");

  NSLog(@"here3: %@", [[[NSString alloc] initWithBytes:eventData length:eventLength encoding:NSUTF8StringEncoding] autorelease]);

  write(STDOUT_FILENO, eventData, eventLength);
  fflush(stdout);
}

typedef void (*data_available_callback)(int fd, NSData *data, void *context);

static void DataIsAvailable(int fd, NSData *data, void *context)
{
  NSMutableString *dataAsString = [[[NSMutableString alloc] initWithData:data
                                                                encoding:NSUTF8StringEncoding] autorelease];
  // indent the lines
  [dataAsString replaceOccurrencesOfString:@"\n"
                                withString:@"\n    "
                                   options:0
                                     range:NSMakeRange(0, [dataAsString length])];
  [dataAsString insertString:@"    " atIndex:0];

  fprintf(stderr, "-------------------------------------\n");
  fprintf(stderr,
          "RECV '%s' DATA (%lu bytes, fd = %d) --\n",
          (char *)context,
          (size_t)[data length],
          fd);
  fprintf(stderr, "%s\n", [dataAsString UTF8String]);
  fflush(stderr);


//  NSLog(@"\n\n\ %d (%lu bytes) >>>\n%@\n <<<< \n\n\n", fd, (unsigned long)[data length], [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease]);
}

static void ReadFromPipesAndCallbackWithData(int *fds,
                                             data_available_callback *callbacks,
                                             void **contexts,
                                             int count)
{
  struct kevent *waitEvents = calloc(count, sizeof(kevent));
  assert(waitEvents != NULL);

  BOOL *fdIsClosed = calloc(count, sizeof(BOOL));
  assert(fdIsClosed != NULL);

  // Keep track of how many EOF's we've seen - we return when all are finished.
  int numFdsClosed = 0;

  struct kevent *triggeredEvents = calloc(count, sizeof(struct kevent));
  assert(triggeredEvents != NULL);

  for (int i = 0; i < count; i++) {
    void *udata = (void *)i;
    EV_SET(&waitEvents[i], fds[i], EVFILT_READ, EV_ADD, 0, 0, udata);
  }

  int queue = kqueue();

  while (numFdsClosed < count) {
    memset(triggeredEvents, 0, count * sizeof(struct kevent));
    int numEvents = kevent(queue, waitEvents, count, triggeredEvents, count, NULL);

    for (int i = 0; i < numEvents; i++) {
      int fd = (int)triggeredEvents[i].ident;
      int fdIndex = (int)triggeredEvents[i].udata;
      size_t bytesAvailable = (size_t)triggeredEvents[i].data;

      void *dataBytes = malloc(bytesAvailable);
      assert(dataBytes != NULL);

      size_t bytesRead = read(fd, dataBytes, bytesAvailable);
      assert(bytesRead == bytesAvailable);

      NSData *data = [[[NSData alloc] initWithBytesNoCopy:dataBytes
                                                   length:bytesRead
                                             freeWhenDone:YES] autorelease];
      callbacks[i](fd, data, contexts[fdIndex]);

      if ((triggeredEvents[i].flags & EV_EOF) > 0) {
        if (!fdIsClosed[fdIndex]) {
          fdIsClosed[fdIndex] = YES;
          numFdsClosed++;
        }
      }
    }
  }

  if (waitEvents != NULL) {
    free(waitEvents);
    waitEvents = NULL;
  }
  if (triggeredEvents != NULL) {
    free(triggeredEvents);
    triggeredEvents = NULL;
  }
  if (fdIsClosed != NULL) {
    free(fdIsClosed);
    fdIsClosed = NULL;
  }
}

__attribute__((constructor)) static void EntryPoint()
{
  // Unset so we don't cascade into any other process that might be spawned.
  unsetenv("DYLD_INSERT_LIBRARIES");

  NSCAssert(pipe(__eventPipeFds) == 0, @"pipe() failed: %s", strerror(errno));

  int stdoutPipes[2];
  int stderrPipes[2];
  NSCAssert(pipe(stdoutPipes) == 0, @"pipe() failed: %s", strerror(errno));
  NSCAssert(pipe(stderrPipes) == 0, @"pipe() failed: %s", strerror(errno));

  pid_t childPid = fork();
  NSCAssert(childPid != 1, @"fork() failed: %s", strerror(errno));

  if (childPid == 0) {
    // The fork
    printf("in fork!\n");

    // We'll only read from this pipe.
    close(__eventPipeFds[WRITE_SIDE]);
    close(stdoutPipes[WRITE_SIDE]);
    close(stderrPipes[WRITE_SIDE]);

    int pipes[] = {
      __eventPipeFds[READ_SIDE],
      stdoutPipes[READ_SIDE],
      stderrPipes[READ_SIDE],
    };
    data_available_callback callbacks[] = {
      DataIsAvailable,
      DataIsAvailable,
      DataIsAvailable,
    };
    void *contexts[] = {
      "EVENTS",
      "STDOUT",
      "STDERR",
    };

    ReadFromPipesAndCallbackWithData(pipes, callbacks, contexts, 3);

    // Explicitly exit - otherwise dyld will keep loading all the libs that come
    // after otest-shim and eventually we'll run the tests again.
    exit(0);
  } else {
    // The original otest or TEST_HOST process.
    printf("in host!\n");

    // We'll only write to this pipe.
    close(__eventPipeFds[READ_SIDE]);
    close(stdoutPipes[READ_SIDE]);
    close(stderrPipes[READ_SIDE]);

    __eventPipeWriteSide = fdopen(__eventPipeFds[WRITE_SIDE], "w");

    // Redirect all stdout & stderr to the pipes.
    if (dup2(stdoutPipes[WRITE_SIDE], STDOUT_FILENO) == -1) {
      fprintf(stderr, "Couldn't dup2(%d, %d): %s\n",
              stdoutPipes[WRITE_SIDE], STDOUT_FILENO, strerror(errno));
      exit(1);
    }

    if (dup2(stderrPipes[WRITE_SIDE], STDERR_FILENO) == -1) {
      fprintf(stderr, "Couldn't dup2(%d, %d): %s\n",
              stderrPipes[WRITE_SIDE], STDERR_FILENO, strerror(errno));
      exit(1);
    }

    // We need to swizzle SenTestLog (part of SenTestingKit), but the test bundle
    // which links SenTestingKit hasn't been loaded yet.  Let's register to get
    // notified when libraries are initialized and we'll watch for SenTestingKit.
    dyld_register_image_state_change_handler(dyld_image_state_initialized,
                                             NO,
                                             DyldImageStateChangeHandler);
  }
}

