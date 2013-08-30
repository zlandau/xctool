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

#import <Foundation/Foundation.h>
#import "Reporter.h"
#import "OCTestSuiteEventState.h"

@interface OCUnitTestRunner : Reporter {
@public
  NSDictionary *_buildSettings;
  NSArray *_senTestList;
  NSArray *_arguments;
  NSDictionary *_environment;
  BOOL _garbageCollection;
  BOOL _freshSimulator;
  BOOL _freshInstall;
  NSString *_simulatorType;
  NSArray *_reporters;
  OCTestSuiteEventState *_testSuiteState;
  OCTestEventState *_previousTestState;
}

/**
 * Filters a list of test class names to only those that match the
 * senTestList and senTestInvertScope constraints.
 *
 * @param testCases An array of test cases ('ClassA/test1', 'ClassB/test2')
 * @param senTestList SenTestList string.  e.g. "All", "None", "ClsA,ClsB"
 * @param senTestInvertScope YES if scope should be inverted.
 */
+ (NSArray *)filterTestCases:(NSArray *)testCases
             withSenTestList:(NSString *)senTestList
          senTestInvertScope:(BOOL)senTestInvertScope;

- (id)initWithBuildSettings:(NSDictionary *)buildSettings
                senTestList:(NSArray *)senTestList
                  arguments:(NSArray *)arguments
                environment:(NSDictionary *)environment
          garbageCollection:(BOOL)garbageCollection
             freshSimulator:(BOOL)freshSimulator
               freshInstall:(BOOL)freshInstall
              simulatorType:(NSString *)simulatorType
                  reporters:(NSArray *)reporters;

- (BOOL)runTestsWithError:(NSString **)error;

- (NSArray *)otestArguments;
- (NSDictionary *)otestEnvironmentWithOverrides:(NSDictionary *)overrides;

- (NSString *)testBundlePath;

@end
