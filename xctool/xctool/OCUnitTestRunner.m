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

#import "OCUnitTestRunner.h"

#import <QuartzCore/QuartzCore.h>

#import "ReportStatus.h"
#import "XCToolUtil.h"
#import "ReporterEvents.h"
#import "OCTestEventState.h"
#import "OCTestSuiteEventState.h"

@implementation OCUnitTestRunner

- (id)initWithBuildSettings:(NSDictionary *)buildSettings
                senTestList:(NSArray *)senTestList
                  arguments:(NSArray *)arguments
                environment:(NSDictionary *)environment
          garbageCollection:(BOOL)garbageCollection
             freshSimulator:(BOOL)freshSimulator
               freshInstall:(BOOL)freshInstall
              simulatorType:(NSString *)simulatorType
                  reporters:(NSArray *)reporters
{
  if (self = [super init]) {
    _buildSettings = [buildSettings retain];
    _senTestList = [senTestList retain];
    _arguments = [arguments retain];
    _environment = [environment retain];
    _garbageCollection = garbageCollection;
    _freshSimulator = freshSimulator;
    _freshInstall = freshInstall;
    _simulatorType = [simulatorType retain];
    _reporters = [reporters retain];
  }
  return self;
}

- (void)dealloc
{
  [_buildSettings release];
  [_senTestList release];
  [_arguments release];
  [_environment release];
  [_simulatorType release];
  [_reporters release];
  [super dealloc];
}

- (BOOL)runTestsAndFeedOutputTo:(void (^)(NSString *))outputLineBlock
              gotUncaughtSignal:(BOOL *)gotUncaughtSignal
                          error:(NSString **)error
{
  // Subclasses will override this method.
  return NO;
}

- (NSArray *)collectCrashReportPaths
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *diagnosticReportsPath = [@"~/Library/Logs/DiagnosticReports" stringByStandardizingPath];

  BOOL isDirectory = NO;
  BOOL fileExists = [fm fileExistsAtPath:diagnosticReportsPath
                             isDirectory:&isDirectory];
  if (!fileExists || !isDirectory) {
    return @[];
  }

  NSError *error = nil;
  NSArray *allContents = [fm contentsOfDirectoryAtPath:diagnosticReportsPath
                                                 error:&error];
  NSAssert(error == nil, @"Failed getting contents of directory: %@", error);

  NSMutableArray *matchingContents = [NSMutableArray array];

  for (NSString *path in allContents) {
    if ([[path pathExtension] isEqualToString:@"crash"]) {
      NSString *fullPath = [[@"~/Library/Logs/DiagnosticReports" stringByAppendingPathComponent:path] stringByStandardizingPath];
      [matchingContents addObject:fullPath];
    }
  }

  return matchingContents;
}

- (NSString *)concatenatedCrashReports:(NSArray *)reports
{
  NSMutableString *buffer = [NSMutableString string];

  for (NSString *path in reports) {
    NSString *crashReportText = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    // Throw out everything below "Binary Images" - we mostly just care about the thread backtraces.
    NSString *minimalCrashReportText = [crashReportText substringToIndex:[crashReportText rangeOfString:@"\nBinary Images:"].location];

    [buffer appendFormat:@"CRASH REPORT: %@\n\n", [path lastPathComponent]];
    [buffer appendString:minimalCrashReportText];
    [buffer appendString:@"\n"];
  }

  return buffer;
}

- (void)beginTestSuite:(NSDictionary *)event
{
  if (_testSuiteState) {
    [_testSuiteState release];
    _testSuiteState = nil;
  }

  _testSuiteState =
  [[OCTestSuiteEventState alloc] initWithName:event[kReporter_BeginTestSuite_SuiteKey]
                                    reporters:_reporters];
  [_testSuiteState addTestsFromArray:_senTestList];
  [_testSuiteState beginTestSuite];
}

- (void)beginTest:(NSDictionary *)event
{
  NSAssert(_testSuiteState, @"Starting test without a test suite");
  NSString *testName = event[kReporter_BeginTest_TestKey];
  OCTestEventState *state = [_testSuiteState getTestWithTestName:testName];
  NSAssert(state, @"Can't find test state for '%@'", testName);
  [state stateBeginTest];

  if (_previousTestState) {
    [_previousTestState release];
    _previousTestState = nil;
  }
}

- (void)endTest:(NSDictionary *)event
{
  NSAssert(_testSuiteState, @"Ending test without a test suite");
  NSString *testName = event[kReporter_EndTest_TestKey];
  OCTestEventState *state = [_testSuiteState getTestWithTestName:testName];
  NSAssert(state, @"Can't find test state for '%@'", testName);
  [state stateEndTest:[event[kReporter_EndTest_SucceededKey] intValue]
               result:event[kReporter_EndTest_ResultKey]
             duration:[event[kReporter_EndTest_TotalDurationKey] doubleValue]];

  if (_previousTestState) {
    _previousTestState = [state retain];
  }
}

- (void)endTestSuite:(NSDictionary *)event
{
  [_testSuiteState endTestSuite];
}

- (void)testOutput:(NSDictionary *)event
{
  OCTestEventState *test = [_testSuiteState runningTest];

  NSAssert(test, @"Got output with no test running");
  [test stateTestOutput:event[kReporter_TestOutput_OutputKey]];
}

- (NSString *)collectCrashReports:(NSSet *)crashReportsAtStart
{
  // Wait for a moment to see if a crash report shows up.
  NSSet *crashReportsAtEnd = [NSSet setWithArray:[self collectCrashReportPaths]];
  CFTimeInterval start = CACurrentMediaTime();

  while ([crashReportsAtEnd isEqualToSet:crashReportsAtStart] && (CACurrentMediaTime() - start < 10.0)) {
    [NSThread sleepForTimeInterval:0.25];
    crashReportsAtEnd = [NSSet setWithArray:[self collectCrashReportPaths]];
  }

  NSMutableSet *crashReportsGenerated = [NSMutableSet setWithSet:crashReportsAtEnd];
  [crashReportsGenerated minusSet:crashReportsAtStart];
  NSString *concatenatedCrashReports = [self concatenatedCrashReports:[crashReportsGenerated allObjects]];
  return concatenatedCrashReports;
}

- (void)emitFakeTestWithName:(NSString *)testName andOutput:(NSString *)testOutput
{
  OCTestEventState *fakeTest =
  [[OCTestEventState alloc] initWithInputName:testName];

  [_testSuiteState addTest:fakeTest];
  [fakeTest appendOutput:testOutput];

  [fakeTest stateBeginTest];
  [fakeTest publishEvents];
  [fakeTest release];
}

- (void)emitFakeTestSuiteWithName:(NSString *)suiteName
                      andTestName:(NSString *)testName
                        andOutput:(NSString *)testOutput
{
  OCTestSuiteEventState *fakeTestSuite =
  [[OCTestSuiteEventState alloc] initWithName:suiteName
                                    reporters:_reporters];
  OCTestEventState *fakeTest =
  [[OCTestEventState alloc] initWithInputName:testName];

  [fakeTestSuite addTest:fakeTest];
  [fakeTest appendOutput:testOutput];
  [fakeTestSuite publishEvents];
  [fakeTest release];
  [fakeTestSuite release];
}

- (void)handleEarlyTermination:(NSSet *)crashReportsAtStart
{
  // There are four known possibilites here:
  // 1) We crashed before a test suite even started
  // 2) We crashed after the test suite finished
  // 3) We crashed while running a test
  // 4) We crash after running a test, but it was probably caused by that test
  if (!_testSuiteState || ![_testSuiteState isStarted]) {
    [self emitFakeTestSuiteWithName:@"TestSuitePreCrash"
                        andTestName:@"TestSuitePreCrash/handler"
                          andOutput:[NSString stringWithFormat:
                                     @"The test binary crashed before starting a test-suite\n"
                                     @"\n"
                                     @"%@",
                                     [self collectCrashReports:crashReportsAtStart]]];
  } else if ([_testSuiteState isFinished]) {
    [self emitFakeTestSuiteWithName:@"TestSuitePostCrash"
                        andTestName:@"TestSuitePostCrash/handler"
                          andOutput:[NSString stringWithFormat:
                                     @"The test binary crashed after finishing a test-suite\n"
                                     @"\n"
                                     @"%@",
                                     [self collectCrashReports:crashReportsAtStart]]];
  } else if ([_testSuiteState runningTest]) {
    [[_testSuiteState runningTest] appendOutput:[self collectCrashReports:crashReportsAtStart]];
  } else if (_previousTestState) {
    NSString *testName =  [NSString stringWithFormat:@"%@/%@_MAYBE_CRASHED",
                           [_previousTestState className],
                           [_previousTestState methodName]];
    NSString *testOutput = [NSString stringWithFormat:
                            @"The tests crashed immediately after running '%@'.  Even though that test finished, it's "
                            @"likely responsible for the crash.\n"
                            @"\n"
                            @"Tip: Consider re-running this test in Xcode with NSZombieEnabled=YES.  A common cause for "
                            @"these kinds of crashes is over-released objects.  OCUnit creates a NSAutoreleasePool "
                            @"before starting your test and drains it at the end of your test.  If an object has been "
                            @"over-released, it'll trigger an EXC_BAD_ACCESS crash when draining the pool.\n"
                            @"\n"
                            @"%@",
                            [_previousTestState testName],
                            [self collectCrashReports:crashReportsAtStart]];
    [self emitFakeTestWithName:testName andOutput:testOutput];
  }

  if (_previousTestState) {
    [_previousTestState release];
  }
}

- (BOOL)runTestsWithError:(NSString **)error {
  __block BOOL didReceiveTestEvents = NO;

  void (^feedOutputToBlock)(NSString *) = ^(NSString *line) {
    NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];

    [self parseAndHandleEvent: line];
    [_reporters makeObjectsPerformSelector:@selector(publishDataForEvent:) withObject:lineData];

    didReceiveTestEvents = YES;
  };

  NSSet *crashReportsAtStart = [NSSet setWithArray:[self collectCrashReportPaths]];

  NSString *runTestsError = nil;
  BOOL didTerminateWithUncaughtSignal = NO;

  BOOL succeeded = [self runTestsAndFeedOutputTo:feedOutputToBlock
                                 gotUncaughtSignal:&didTerminateWithUncaughtSignal
                                             error:&runTestsError];
  if (runTestsError) {
    *error = runTestsError;
  }

  if (!succeeded && runTestsError == nil && !didReceiveTestEvents) {
    // otest failed but clearly no tests ran.  We've seen this when a test target had no
    // source files.  In that case, xcodebuild generated the test bundle, but didn't build the
    // actual mach-o bundle/binary (because of no source files!)
    //
    // e.g., Xcode would generate...
    //   DerivedData/Something-ejutnghaswljrqdalvadkusmnhdc/Build/Products/Debug-iphonesimulator/SomeTests.octest
    //
    // but, you would not have...
    //   DerivedData/Something-ejutnghaswljrqdalvadkusmnhdc/Build/Products/Debug-iphonesimulator/SomeTests.octest/SomeTests
    //
    // otest would then exit immediately with...
    //   The executable for the test bundle at /path/to/Something/Facebook-ejutnghaswljrqdalvadkusmnhdc/Build/Products/
    //     Debug-iphonesimulator/SomeTests.octest could not be found.
    //
    // Xcode (via Cmd-U) just counts this as a pass even though the exit code from otest was non-zero.
    // That seems a little wrong, but we'll do the same.
    succeeded = YES;
  }

  if (_testSuiteState) {
    // The test runner must have crashed.
    if (didTerminateWithUncaughtSignal) {
      [self handleEarlyTermination:crashReportsAtStart];
    }

    [[_testSuiteState tests] enumerateObjectsUsingBlock:^(OCTestEventState *testState, NSUInteger idx, BOOL *stop) {
      if (![testState isStarted]) {
        if (didTerminateWithUncaughtSignal) {
          [testState stateTestOutput:@"Skipped due to test suite crashing\n"];
        } else {
          [testState stateTestOutput:@"Skipped due to a previous test crashing\n"];
        }
      }
    }];
    [_testSuiteState publishEvents];
    [_testSuiteState release];
    _testSuiteState = nil;
  }

  return succeeded;
}

- (NSArray *)otestArguments
{
  // These are the same arguments Xcode would use when invoking otest.  To capture these, we
  // just ran a test case from Xcode that dumped 'argv'.  It's a little tricky to do that outside
  // of the 'main' function, but you can use _NSGetArgc and _NSGetArgv.  See --
  // http://unixjunkie.blogspot.com/2006/07/access-argc-and-argv-from-anywhere.html
  NSMutableArray *args = [NSMutableArray arrayWithArray:@[
           // Not sure exactly what this does...
           @"-NSTreatUnknownArgumentsAsOpen", @"NO",
           // Not sure exactly what this does...
           @"-ApplePersistenceIgnoreState", @"YES",
           // SenTest is one of Self, All, None,
           // or TestClassName[/testCaseName][,TestClassName2]
           @"-SenTest", _senTestList,
           // SenTestInvertScope optionally inverts whatever SenTest would normally select.
           // We never invert, since we always pass the exact list of test cases
           // to be run.
           @"-SenTestInvertScope", @"NO",
           ]];

  // Add any argments that might have been specifed in the scheme.
  [args addObjectsFromArray:_arguments];

  return args;
}

- (NSDictionary *)otestEnvironmentWithOverrides:(NSDictionary *)overrides
{
  NSMutableDictionary *env = [NSMutableDictionary dictionary];

  NSArray *layers = @[
                      // Xcode will let your regular environment pass-thru to
                      // the test.
                      [[NSProcessInfo processInfo] environment],
                      // Any special environment vars set in the scheme.
                      _environment,
                      // Whatever values we need to make the test run at all for
                      // ios/mac or logic/application tests.
                      overrides,
                      ];
  for (NSDictionary *layer in layers) {
    [layer enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop){
      if ([key isEqualToString:@"DYLD_INSERT_LIBRARIES"]) {
        // It's possible that the scheme (or regular host environment) has its
        // own value for DYLD_INSERT_LIBRARIES.  In that case, we don't want to
        // stomp on it when insert otest-shim.
        NSString *existingVal = env[key];
        if (existingVal) {
          env[key] = [existingVal stringByAppendingFormat:@":%@", val];
        } else {
          env[key] = val;
        }
      } else {
        env[key] = val;
      }
    }];
  }

  return env;
}

- (NSString *)testBundlePath
{
  return [NSString stringWithFormat:@"%@/%@",
          _buildSettings[@"BUILT_PRODUCTS_DIR"],
          _buildSettings[@"FULL_PRODUCT_NAME"]
          ];
}

@end
