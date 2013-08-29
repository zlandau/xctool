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

#import <SenTestingKit/SenTestingKit.h>

#import "OCEventStateTests.h"
#import "OCTestEventState.h"
#import "ReporterEvents.h"
#import "FakeFileHandle.h"
#import "ReporterTask.h"
#import "XCToolUtil.h"

@interface OCTestEventStateTests : OCEventStateTests
@end

@implementation OCTestEventStateTests

- (void)testInitWithInputName
{
  OCTestEventState *state =
    [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"
                                       reporters: @[]] autorelease];

  assertThat([state testName], equalTo(@"-[ATestClass aTestMethod]"));
}

- (void)testInitWithInvalidInputName
{
  STAssertThrowsSpecific([[[OCTestEventState alloc] initWithInputName:@"ATestClassaTestMethod"
                                                            reporters: @[]] autorelease],
                         NSException, @"Invalid class name should have raised exception");
}

- (void)testPublishFromStarted
{
  OCTestEventState *state =
   [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

   assertThatBool(state.isStarted, equalToBool(NO));
   assertThatBool(state.isFinished, equalToBool(NO));

  [state stateBeginTest];

  assertThatBool(state.isStarted, equalToBool(YES));
  assertThatBool(state.isFinished, equalToBool(NO));

  NSArray *events = [self getPublishedEventsForState:state
                                           withBlock:^{
                                             [state publishEvents];
                                           }];
  assertThatInteger([events count], equalToInteger(1));
  assertThat(events[0][@"event"], is(kReporter_Events_EndTest));
  assertThat(events[0][kReporter_EndTest_SucceededKey], is(@NO));
  assertThat(events[0][kReporter_EndTest_ResultKey], is(@"error"));

  assertThatBool(state.isStarted, equalToBool(YES));
  assertThatBool(state.isFinished, equalToBool(YES));
}

- (void)testPublishFromNotStarted
{
  OCTestEventState *state =
  [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  assertThatBool(state.isStarted, equalToBool(NO));
  assertThatBool(state.isFinished, equalToBool(NO));

  NSArray *events = [self getPublishedEventsForState:state
                                           withBlock:^{
                                             [state publishEvents];
                                           }];

  assertThatInteger([events count], equalToInteger(2));
  assertThat(events[0], equalTo(@{
                                @"event":kReporter_Events_BeginTest,
                                kReporter_EndTest_TestKey:@"-[ATestClass aTestMethod]",
                                kReporter_EndTest_ClassNameKey:@"ATestClass",
                                kReporter_EndTest_MethodNameKey:@"aTestMethod",
                                }));
  assertThat(events[1][@"event"], is(kReporter_Events_EndTest));
  assertThat(events[1][kReporter_EndTest_SucceededKey], is(@NO));
  assertThat(events[1][kReporter_EndTest_ResultKey], is(@"error"));

  assertThatBool(state.isStarted, equalToBool(YES));
  assertThatBool(state.isFinished, equalToBool(YES));
}

- (void)testStates
{
  OCTestEventState *state =
  [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  assertThatBool(state.isStarted, equalToBool(NO));
  assertThatBool(state.isFinished, equalToBool(NO));
  assertThatBool(state.isSuccessful, equalToBool(NO));
  assertThatBool([state isRunning], equalToBool(NO));
  assertThat(state.result, is(@"error"));

  [state stateBeginTest];

  assertThatBool(state.isStarted, equalToBool(YES));
  assertThatBool(state.isFinished, equalToBool(NO));
  assertThatBool(state.isSuccessful, equalToBool(NO));
  assertThatBool([state isRunning], equalToBool(YES));

  [state stateEndTest:YES result: @"success"];

  assertThatBool(state.isStarted, equalToBool(YES));
  assertThatBool(state.isFinished, equalToBool(YES));
  assertThatBool(state.isSuccessful, equalToBool(YES));
  assertThatBool([state isRunning], equalToBool(NO));
  assertThat(state.result, is(@"success"));

  state =
    [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];
  [state stateBeginTest];
  [state stateEndTest:NO result: @"failure"];

  assertThatBool(state.isStarted, equalToBool(YES));
  assertThatBool(state.isFinished, equalToBool(YES));
  assertThatBool(state.isSuccessful, equalToBool(NO));
  assertThatBool([state isRunning], equalToBool(NO));
  assertThat(state.result, is(@"failure"));

}

- (void)testOutput
{
  OCTestEventState *state =
  [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  [state stateBeginTest];
  [state stateTestOutput:@"some output\n"];
  [state stateTestOutput:@"more output\n"];
  NSArray *events = [self getPublishedEventsForState:state
                                           withBlock:^{
                                             [state publishEvents];
                                           }];

  assertThatInteger([events count], equalToInteger(1));
  assertThat(events[0][@"event"], is(kReporter_Events_EndTest));
  assertThat(events[0][kReporter_EndTest_OutputKey], is(@"some output\nmore output\n"));
}

- (void)testPublishOutput
{
  OCTestEventState *state =
  [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  [state stateBeginTest];
  [state stateTestOutput:@"some output\n"];
  [state stateTestOutput:@"more output\n"];
  [state appendOutput:@"output from us\n"];
  NSArray *events = [self getPublishedEventsForState:state
                                           withBlock:^{
                                             [state publishOutput];
                                           }];

  assertThatInteger([events count], equalToInteger(1));
  assertThat(events[0], equalTo(@{
                                @"event":kReporter_Events_TestOuput,
                                kReporter_TestOutput_OutputKey:@"output from us\n"
                                }));
}

- (void)testAppendOutput
{
  OCTestEventState *state =
  [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  [state stateBeginTest];
  [state stateTestOutput:@"some output\n"];
  [state stateTestOutput:@"more output\n"];
  [state appendOutput:@"output from us\n"];
  NSArray *events = [self getPublishedEventsForState:state
                                           withBlock:^{
                                             [state publishEvents];
                                           }];

  assertThatInteger([events count], equalToInteger(2));
  assertThat(events[0], equalTo(@{
                                @"event":kReporter_Events_TestOuput,
                                kReporter_TestOutput_OutputKey:@"output from us\n"
                                }));
  assertThat(events[1][@"event"], is(kReporter_Events_EndTest));
  assertThat(events[1][kReporter_EndTest_OutputKey], is(@"some output\nmore output\noutput from us\n"));
}

- (void)testDuration
{
  OCTestEventState *state =
  [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  [state stateBeginTest];
  NSArray *events = [self getPublishedEventsForState:state
                                           withBlock:^{
                                             [state publishEvents];
                                           }];

  assertThatInteger([events count], equalToInteger(1));
  assertThatFloat(state.duration, greaterThan(@0.0));
  assertThat(events[0][kReporter_EndTest_TotalDurationKey], closeTo(state.duration, 0.005f));
}

- (void)testEndWithDuration
{
  OCTestEventState *state =
    [[[OCTestEventState alloc] initWithInputName:@"ATestClass/aTestMethod"] autorelease];

  [state stateBeginTest];
  [state stateEndTest:YES result:@"success" duration:123.4];

  assertThatFloat(state.duration, closeTo(123.4, 0.005f));
}

@end
