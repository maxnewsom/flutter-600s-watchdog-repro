//
//  RunnerTests.m
//  RunnerTests
//
//  Created by Mootaz Bahri on 06.12.24.
//

@import XCTest;
@import integration_test;
@import UIKit;

#ifndef REPRO_DISABLE_MACRO_RUNNER
INTEGRATION_TEST_IOS_RUNNER(RunnerTests)
#endif

// 600s Sauce Labs result-listener repro: sequential native tests.
//
// Unlike RunnerTests above (whose Flutter-driven results all surface in a
// single burst at the very end of the Dart run), each test method here
// sleeps ~2 minutes and reports its own pass/fail to XCTest immediately on
// completion. This isolates whether Sauce Labs' "listening for a test
// result" timeout resets on discrete per-test XCTest completions, as
// opposed to being a fixed cap from job start.
@interface SequentialTimeoutReproTests : XCTestCase
@end

@implementation SequentialTimeoutReproTests

- (void)runSegmentNamed:(NSString *)name {
  NSLog(@"[TimeoutRepro] Starting %@ at %@", name, [NSDate date]);
  [NSThread sleepForTimeInterval:120]; // 2 minutes
  NSLog(@"[TimeoutRepro] Finished %@ at %@", name, [NSDate date]);
  XCTAssertTrue(true);
}

- (void)testSegment1 { [self runSegmentNamed:@"segment 1 of 6"]; }
- (void)testSegment2 { [self runSegmentNamed:@"segment 2 of 6"]; }
- (void)testSegment3 { [self runSegmentNamed:@"segment 3 of 6"]; }
- (void)testSegment4 { [self runSegmentNamed:@"segment 4 of 6"]; }
- (void)testSegment5 { [self runSegmentNamed:@"segment 5 of 6"]; }
- (void)testSegment6 { [self runSegmentNamed:@"segment 6 of 6"]; }

@end

// Xcode construction-phase watchdog workaround, per
// https://github.com/flutter/flutter/issues/145143#issuecomment-4646521807
//
// INTEGRATION_TEST_IOS_RUNNER (RunnerTests above) runs the whole Dart suite
// inside +testInvocations, which executes during XCTestCase *construction* -
// Xcode 15+ kills tests still under construction after a watchdog timeout.
// This class instead drives FLTIntegrationTestRunner from inside a real test
// method, which is not subject to that watchdog. Same trade-off as upstream:
// all Dart tests report as a single XCTest case instead of individual ones.
@interface ConstructionPhaseWorkaroundTests : XCTestCase
@end

@implementation ConstructionPhaseWorkaroundTests

- (void)testIntegrationTest {
  FLTIntegrationTestRunner *integrationTestRunner = [[FLTIntegrationTestRunner alloc] init];

  __block BOOL allTestsPassed = YES;
  __block NSMutableArray<NSString *> *failures = [[NSMutableArray alloc] init];

  [integrationTestRunner testIntegrationTestWithResults:^(SEL testSelector, BOOL success, NSString *failureMessage) {
    if (!success) {
      allTestsPassed = NO;
      NSString *name = NSStringFromSelector(testSelector);
      [failures addObject:[NSString stringWithFormat:@"%@: %@", name, failureMessage ?: @"(no message)"]];
    }
  }];

  NSDictionary<NSString *, UIImage *> *capturedScreenshotsByName = integrationTestRunner.capturedScreenshotsByName;
  [capturedScreenshotsByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, UIImage *screenshot, BOOL *stop) {
    XCTAttachment *attachment = [XCTAttachment attachmentWithImage:screenshot];
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    if (name != nil) {
      attachment.name = name;
    }
    [self addAttachment:attachment];
  }];

  if (!allTestsPassed) {
    XCTFail(@"Flutter integration test failures:\n%@", [failures componentsJoinedByString:@"\n"]);
  }
}

@end
