import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/state/safety_net.dart';

void main() {
  test('auto-reverts when the window expires', () async {
    final net = SafetyNet(window: const Duration(milliseconds: 80));
    var didIt = false;
    var reverted = false;
    await net.guard(
      key: 'k',
      label: 'k',
      doIt: () async {
        didIt = true;
      },
      revert: () async {
        reverted = true;
      },
    );
    expect(didIt, isTrue);
    expect(reverted, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(reverted, isTrue);
    expect(net.activePrompt, isNull);
  });

  test('confirm() stops the revert', () async {
    final net = SafetyNet(window: const Duration(milliseconds: 80));
    var reverted = false;
    await net.guard(
      key: 'k',
      label: 'k',
      doIt: () async {},
      revert: () async {
        reverted = true;
      },
    );
    net.confirm('k');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(reverted, isFalse);
    expect(net.activePrompt, isNull);
  });

  test('revertNow() runs the inverse immediately', () async {
    final net = SafetyNet();
    var reverted = false;
    await net.guard(
      key: 'k',
      label: 'k',
      doIt: () async {},
      revert: () async {
        reverted = true;
      },
    );
    await net.revertNow('k');
    expect(reverted, isTrue);
    expect(net.activePrompt, isNull);
  });

  test(
      'second guard with same key resets timer but keeps the original revert',
      () async {
    final net = SafetyNet(window: const Duration(milliseconds: 120));
    String? revertedWith;
    await net.guard(
      key: 'mode',
      label: 'first',
      doIt: () async {},
      revert: () async {
        revertedWith = 'original';
      },
    );
    // After 60 ms, fire a second guard that *would* install a new revert.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await net.guard(
      key: 'mode',
      label: 'second',
      doIt: () async {},
      revert: () async {
        revertedWith = 'second';
      },
    );
    // Wait for the freshly-armed timer to fire (~120 ms more).
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(revertedWith, equals('original'));
  });
}
