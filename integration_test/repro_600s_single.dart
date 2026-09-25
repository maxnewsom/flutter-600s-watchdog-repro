import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:my_demo_app_flutter/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
      as IntegrationTestWidgetsFlutterBinding;

  binding.platformDispatcher.onSemanticsEnabledChanged = () {};

  group('600s repro - single long-running test', () {
    tearDownAll(() async {
      binding.reportData = <String, dynamic>{'completed': true};
    });

    // Runs past the 600s mark as a single Flutter test. The
    // integration_test iOS runner only reports this test's XCTest result
    // once, at the very end of the run - there is no intermediate result
    // event during execution.
    testWidgets(
      'Runs past 600s with only one XCTest result reported at the end',
      (tester) async {
        app.main();
        await tester.pumpAndSettle();

        const totalRunTime = Duration(minutes: 11);
        const tick = Duration(seconds: 15);
        var elapsed = Duration.zero;
        while (elapsed < totalRunTime) {
          await tester.pump(tick);
          await Future.delayed(tick);
          elapsed += tick;
        }

        expect(true, isTrue);
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });
}
