import 'package:flutter_test/flutter_test.dart';
import 'package:kanshi_gui/state/operation_queue.dart';

void main() {
  test('operations run one at a time, in call order', () async {
    // Applying a layout is a sequence of subprocess calls with awaits between
    // them. Two sequences interleaving means the compositor receives half of
    // each, and the model describes neither.
    final q = OperationQueue();
    final log = <String>[];

    Future<void> op(String name) async {
      log.add('$name start');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      log.add('$name end');
    }

    await Future.wait([q.run(() => op('a')), q.run(() => op('b'))]);
    expect(log, ['a start', 'a end', 'b start', 'b end']);
  });

  test('a failure does not stall the ones behind it', () async {
    final q = OperationQueue();
    final failed = q.run<int>(() async => throw StateError('nope'));
    final after = q.run<int>(() async => 42);

    await expectLater(failed, throwsStateError);
    expect(await after, 42);
  });

  test('the error reaches the caller rather than being swallowed', () async {
    // An operation that failed silently is exactly what M4 removed.
    final q = OperationQueue();
    await expectLater(
      q.run<void>(() async => throw StateError('surfaced')),
      throwsA(isA<StateError>()),
    );
  });

  test('results come back to the right caller', () async {
    final q = OperationQueue();
    final results = await Future.wait([
      q.run(() async => 1),
      q.run(() async => 2),
      q.run(() async => 3),
    ]);
    expect(results, [1, 2, 3]);
  });

  test('busy state brackets the whole queue, not each operation', () async {
    final q = OperationQueue();
    var changes = 0;
    q.onBusyChanged = () => changes++;
    expect(q.isBusy, isFalse);

    final work = Future.wait([
      q.run(() async => Future<void>.delayed(const Duration(milliseconds: 5))),
      q.run(() async => Future<void>.delayed(const Duration(milliseconds: 5))),
    ]);
    expect(q.isBusy, isTrue);
    await work;
    expect(q.isBusy, isFalse);
    expect(changes, 2,
        reason: 'one transition into busy and one back out, not four');
  });

  test('idle waits for the queue to drain', () async {
    final q = OperationQueue();
    var done = false;
    // ignore: unawaited_futures
    q.run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      done = true;
    });
    await q.idle;
    expect(done, isTrue);
  });
}
