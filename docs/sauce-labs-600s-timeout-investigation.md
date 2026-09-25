# Investigation: Sauce Labs XCUITest jobs erroring after ~600s

## Symptom

A customer's iOS XCUITest job on Sauce Labs real devices, built from a Flutter
`integration_test` suite, completes and passes on-device — but any run whose
total duration exceeds ~10 minutes gets reported as **errored** rather than
passed/failed, with:

```
Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000 "Timed out while
preparing execution worker."
UserInfo={NSLocalizedDescription=Timed out while preparing execution worker.}
```

Runs under 10 minutes report a normal pass or fail. The customer's suite
contains 10 Flutter `testWidgets` tests; no single test is believed to run
anywhere near 600s on its own.

## Root cause

This is **Apple's own Xcode 15+ construction-phase watchdog**, not a Sauce
Labs-configured timeout. Background, confirmed by
[flutter/flutter#145143](https://github.com/flutter/flutter/issues/145143)
and reproduced independently here:

- Flutter's `integration_test` iOS runner (the `INTEGRATION_TEST_IOS_RUNNER`
  macro used in `RunnerTests.m`) overrides `+testInvocations` — the method
  XCTest calls during **test discovery/construction**, before any test is
  considered "running."
- That override synchronously blocks, spinning the run loop, until the
  *entire* Dart file finishes and fires one `allTestsFinished` platform
  channel call. Only then does it synthesize XCTest test methods and run
  them in a near-instant final burst.
- **This is true regardless of how many `testWidgets` blocks are in the Dart
  file.** Whether it's 1 test or 10, XCTest sees a single, silent,
  construction-phase blocking call whose length equals the *aggregate* Dart
  runtime — never any incremental progress.
- Xcode 15+ added a watchdog that kills a test bundle if a class is still
  "under construction" (i.e., stuck in `+testInvocations`) past a threshold.
  In our environment that threshold sits at ~600s (the referenced GitHub
  issue reports ~6 minutes in a different environment — the exact value may
  vary by Xcode/OS version or real-device-vs-simulator).
- Because the on-device Dart tests keep running and do eventually finish
  successfully, this produces a **false failure**: the job's real work
  completes fine, but the watchdog kills the process before XCTest ever
  gets to report a result, and the error surfaces as "Timed out while
  preparing execution worker."

Splitting the Dart file into more `testWidgets` blocks does not help — they
are still all bundled into the same single blocking construction-phase call.
The number of logical tests is a red herring; total aggregate Dart runtime
of the file is the only variable that matters here.

## How to tell if this is what's happening to a given job

Check the `xcuitest.log` artifact (downloadable from the Sauce Labs job, or
via `saucectl run`'s `artifacts.download` config). Look for lines matching:

```
Test Case '-[ClassName methodName]' started.
Test Case '-[ClassName methodName]' passed (X.XX seconds).
```

- **Genuinely incremental test methods** (not affected by this issue) show
  one `started`/`passed` pair per test method, spaced out over the job's
  duration, each with a real duration under the watchdog threshold.
- **A job hitting this bug** shows **zero** `Test Case` lines for the
  affected class, and instead ends with:
  ```
  [Default] Error while discovering and preparing to run tests: Error
  Domain=com.apple.dt.XCTest.XCTFuture Code=1000 "Timed out while preparing
  execution worker."
  ```
  i.e. it never leaves the discovery/construction phase for that class.

## Experiments run

All variants built via `make build-ios-ipa-files` (see `Makefile`) and run
via `saucectl run` against Sauce Labs real devices (iPhone, iOS 17.x). Test
sources live in `ios/RunnerTests/RunnerTests.m` and
`integration_test/repro_600s_single.dart`.

| Variant | Structure | Result | Link |
|---|---|---|---|
| A | Single ~11 min Flutter test, run via the stock `INTEGRATION_TEST_IOS_RUNNER` macro (construction phase) | **Failed** — `XCTFuture Code=1000` at ~600s | [job](https://app.saucelabs.com/tests/1e331948b3a24c209c76f94b89412569) |
| B | 6 native `XCTestCase` methods (no Flutter), each sleeping ~2 min, reporting discretely | **Passed** | [job](https://app.saucelabs.com/tests/ac6633fe13524ace831a6962d3edc4de#7) |
| C (confounded) | GitHub-issue workaround class added *alongside* the untouched macro class, scoped with `-only-testing` | Failed — but invalid: XCTest's bundle-wide discovery still invoked the macro class's blocking `+testInvocations` regardless of `-only-testing` scoping, so this never actually tested the workaround | [job](https://app.saucelabs.com/tests/be7442675fe049e9bb113e0d76ca9877) |
| C (corrected) | Same ~11 min Flutter test as Variant A, but driven from inside a real running test method (macro class excluded from the build entirely) | **Passed** | [job](https://app.saucelabs.com/tests/08d071554f3740d0a1bb0896245e3d0a#1) |

The cleanest comparison is **A vs. C (corrected)**: identical Dart test
content, identical "one result reported at the very end" shape — the only
variable changed is construction-phase vs. running-phase execution, and
that alone flipped the outcome. This confirms the construction-phase
watchdog as the cause, not (for example) a Sauce Labs listener requiring
periodic results.

## The workaround

Replace the stock macro invocation in `RunnerTests.m`:

```objc
@import XCTest;
@import integration_test;
INTEGRATION_TEST_IOS_RUNNER(RunnerTests)
```

with a custom `XCTestCase` that drives `FLTIntegrationTestRunner` from
inside an actual test *method* rather than from `+testInvocations`:

```objc
@import XCTest;
@import integration_test;
@import UIKit;

// Custom implementation replacing INTEGRATION_TEST_IOS_RUNNER macro.
//
// The default macro runs all Dart tests inside +testInvocations (the
// XCTestCase construction phase). Xcode 15+ added a watchdog timer that
// kills tests still in construction after a threshold (~6-10 min
// depending on environment), causing long-running integration tests to be
// terminated with a false failure. See:
// https://github.com/flutter/flutter/issues/145143
//
// This implementation moves test execution into an actual test method,
// which is not subject to the construction-phase watchdog. The trade-off
// is that all Dart tests are reported as a single XCTest case instead of
// individual cases.

@interface RunnerTests : XCTestCase
@end

@implementation RunnerTests

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
```

That's the whole change — no Makefile flags, no `-only-testing`, no
splitting into multiple Dart files or multiple jobs. Just swap the contents
of `RunnerTests.m` and rebuild/run exactly as before
(`make build-ios-ipa-files`, then `saucectl run`).

**Trade-off to communicate to the customer:** all 10 of their `testWidgets`
tests will now report as a single XCTest result (`testIntegrationTest`)
instead of 10 individual ones in the Sauce Labs results view. Per-test
pass/fail detail is still available in the failure message text (each
failing Dart test's name and message gets concatenated into the single
`XCTFail` call) and in captured screenshots, just not as separate XCTest
entries.

## Recommendation for the Sauce Labs ticket

Frame this as a **false-failure report**, not a request to raise a timeout:

- The customer's job's on-device work completes and passes; Sauce Labs
  reports it as errored anyway.
- Root cause is Apple's Xcode 15+ construction-phase watchdog, which Sauce
  Labs' XCTest invocation inherits — likely not something Sauce Labs can
  configure away on their end.
- Worth asking support to confirm whether they're aware of this
  interaction with Flutter's `integration_test` package, and whether they'd
  consider documenting the workaround above for other Flutter customers
  hitting the same false failure.
- Attach the paired **A / C (corrected)** jobs above as reproduction
  evidence — same test content, only the construction-vs-running-phase
  variable changed, with a clean pass/fail flip.

## Other things fixed along the way (unrelated to the 600s issue)

- **`Makefile`'s `build-ios-ipa-files` target didn't clean up before
  rebuilding** — `Payload/` and `Runner.ipa` were never removed, so `cp -r`
  merged stale files from prior builds into the app bundle and `zip -r`
  patched an existing archive in place rather than rebuilding it cleanly
  (visible as "Local Entry CRC does not match CD" warnings). Fixed by
  adding `rm -rf Payload Runner.ipa` before rebuilding.
- **Real device signing** required a free Apple ID (Personal Team) added to
  Xcode, a unique bundle identifier (the Flutter template default
  `com.example.*` is globally claimed), and at least one device UDID
  registered via a physical device connected over USB with Developer Mode
  enabled — no paid Apple Developer Program membership needed, since Sauce
  Labs re-signs apps installed on their public device pool with their own
  certificate.
- Saw one transient `"Couldn't find a file with reference: '<uuid>'"`
  error where the referenced file was confirmed present in
  `saucectl storage list` moments later — looked like an upload/job-creation
  consistency race on Sauce Labs' backend rather than anything wrong with
  the local build. Resolved by simply retrying.

## Rebuilding the repro (handoff notes)

`RunnerTests.m` in this repo holds all three experiment classes at once
(stock macro `RunnerTests`, `SequentialTimeoutReproTests`,
`ConstructionPhaseWorkaroundTests`). The stock macro class is wrapped in
`#ifndef REPRO_DISABLE_MACRO_RUNNER`, so which variant you get depends on
the build flags:

```sh
# Variant A - stock macro runner (errors at ~600s)
make build-ios-ipa-files \
  FLUTTER_INTEGRATION_TEST_DART_FILE=$(realpath integration_test/repro_600s_single.dart)
saucectl run -c .sauce/repro_600s_single.yaml

# Variant C (corrected) - workaround, macro class compiled out (passes)
make build-ios-ipa-files \
  FLUTTER_INTEGRATION_TEST_DART_FILE=$(realpath integration_test/repro_600s_single.dart) \
  EXTRA_BUILD_SETTINGS='GCC_PREPROCESSOR_DEFINITIONS="$$(inherited) REPRO_DISABLE_MACRO_RUNNER=1"'
saucectl run -c .sauce/repro_600s_construction_workaround.yaml
```

Notes:
- A plain `make build-ios-ipa-files` builds `flutter_integration_test.dart`
  and includes the stock macro class.
- None of the repro yamls filter by class, so the sequential native tests
  (~12 min) also run alongside whichever Flutter class is compiled in. Add a
  `testOptions` class filter if you want a faster, cleaner run.
- The `xcTestRunFile` names are hardcoded to `Runner_iphoneos26.5-arm64`
  (Xcode 26.5). Update them if your Xcode produces a different name.
- Signing uses a personal Apple team (`DEVELOPMENT_TEAM = 3922WFF73Z`) and
  bundle ID `com.maxjosephnewsom.myDemoAppFlutter`. Swap in your own team
  and a unique bundle ID in Xcode before building for real devices.
- For the customer, ship only the clean `RunnerTests.m` replacement shown in
  "The workaround" above, not this three-class experiment file.
