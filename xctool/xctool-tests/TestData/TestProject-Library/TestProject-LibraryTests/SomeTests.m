//
//  TestProject_LibraryTests.m
//  TestProject-LibraryTests
//
//  Created by Fred Potter on 1/23/13.
//
//

#import "SomeTests.h"
#import <UIKit/UIKit.h>

@implementation SomeTests

- (void)setUp
{
    [super setUp];

    // Set-up code here.
}

- (void)tearDown
{
    // Tear-down code here.

    [super tearDown];
}

- (void)testPrintSDK
{
  printf("%s: SDK: %s\n", __PRETTY_FUNCTION__, [[UIDevice currentDevice].systemVersion UTF8String]);
}

- (void)testWillPass
{
  printf("In %s\n", __PRETTY_FUNCTION__);
  STAssertTrue(YES, nil);
}

- (void)testWillFail
{
  printf("In %s\n", __PRETTY_FUNCTION__);
  STAssertEqualObjects(@"a", @"b", @"Strings aren't equal");
}

- (void)testOutputMerging {
  fprintf(stdout, "%s: stdout-line1\n", __PRETTY_FUNCTION__);
  fprintf(stderr, "%s: stderr-line1\n", __PRETTY_FUNCTION__);
  fprintf(stdout, "%s: stdout-line2\n", __PRETTY_FUNCTION__);
  fprintf(stdout, "%s: stdout-line3\n", __PRETTY_FUNCTION__);
  fprintf(stderr, "%s: stderr-line2\n", __PRETTY_FUNCTION__);
  fprintf(stderr, "%s: stderr-line3\n", __PRETTY_FUNCTION__);
  STAssertTrue(YES, nil);
}

@end
