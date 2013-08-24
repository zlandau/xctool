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

#import "OCEventState.h"
#import "ReporterEvents.h"
#import "FakeFileHandle.h"
#import "ReporterTask.h"
#import "XCToolUtil.h"

@interface OCEventStateTests : SenTestCase
@end

@implementation OCEventStateTests

- (void)testParseEvent
{
  OCEventState *state = [[[OCEventState alloc] initWithReporters: @[]] autorelease];
  STAssertEqualObjects([state reporters], @[], @"Reporters are not equal");

}

- (void)assertThat:(OCEventState *)state
        didPublish:(NSDictionary *)event
         withBlock:(void (^)(void))block
{
  NSArray *events = [self getPublishedEventsForState:state withBlock: block];
  assertThatInteger([events count], equalToInteger(1));
  assertThat(events[0], equalTo(event));
}

- (void)assertThat:(OCEventState *)state
        didPublish:(NSDictionary *)event
{
  NSArray *events = [self getPublishedEventsForState:state withBlock:^{
    [state publishEvents];
  }];
  assertThatInteger([events count], equalToInteger(1));
  assertThat(events[0], equalTo(event));
}

- (NSArray *)getPublishedEventsForStates:(NSArray *)states
                               withBlock:(void (^)(void))block
{
  NSString *fakeStandardOutputPath = MakeTempFileWithPrefix(@"fake-stdout");
  NSString *fakeStandardErrorPath = MakeTempFileWithPrefix(@"fake-stderr");

  ReporterTask *rt = [[[ReporterTask alloc] initWithReporterPath:@"/bin/cat"
                                                      outputPath:@"-"] autorelease];
  NSString *error = nil;
  BOOL opened = [rt openWithStandardOutput:[NSFileHandle fileHandleForWritingAtPath:fakeStandardOutputPath]
                             standardError:[NSFileHandle fileHandleForWritingAtPath:fakeStandardErrorPath]
                                     error:&error];
  assertThatBool(opened, equalToBool(YES));

  [states makeObjectsPerformSelector:@selector(setReporters:) withObject:@[rt]];

  block();

  [rt close];

  NSString *fakeStandardOutput = [NSString stringWithContentsOfFile:fakeStandardOutputPath
                                                           encoding:NSUTF8StringEncoding
                                                              error:nil];

  NSMutableArray *events = [[NSMutableArray alloc] init];
  NSMutableArray *lines = [[fakeStandardOutput componentsSeparatedByString:@"\n"] mutableCopy];;
  [lines removeObjectAtIndex:[lines count] - 1];
  [lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger idx, BOOL *stop) {
      NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
      [events addObject: [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:nil]];
    }];

  return events;
}

- (NSArray *)getPublishedEventsForState:(OCEventState *)state
                              withBlock:(void (^)(void))block
{
  return [self getPublishedEventsForStates:@[state] withBlock:block];
}


- (void)testPublishWithEvent
{
  NSDictionary *event = @{@"ilove": @"jello"};
  OCEventState *state = [[[OCEventState alloc] initWithReporters:@[]] autorelease];
  [self assertThat:state
        didPublish:event
         withBlock:^{
           [state publishWithEvent:event];
         }];
}

@end
