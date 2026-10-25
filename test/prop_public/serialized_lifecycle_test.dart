import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:prop/utils/serialized_lifecycle.dart';

void main() {
  test('runs operations one at a time, in call order', () async {
    final lifecycle = SerializedLifecycle();
    final log = <String>[];
    Future<void> op(String name, int ms) async {
      log.add('$name start');
      await Future<void>.delayed(Duration(milliseconds: ms));
      log.add('$name end');
    }

    await Future.wait([
      lifecycle.run(() => op('a', 30)),
      lifecycle.run(() => op('b', 5)),
      lifecycle.run(() => op('c', 1)),
    ]);
    expect(log, ['a start', 'a end', 'b start', 'b end', 'c start', 'c end']);
  });

  test('a failing operation fails its own future and not the next', () async {
    final lifecycle = SerializedLifecycle();
    final failing = lifecycle.run<void>(() async => throw StateError('boom'));
    final next = lifecycle.run(() async => 42);
    await expectLater(failing, throwsStateError);
    expect(await next, 42);
  });

  test('returns each operation\'s own result', () async {
    final lifecycle = SerializedLifecycle();
    expect(await lifecycle.run(() async => 'x'), 'x');
    expect(await lifecycle.run(() async => 7), 7);
  });

  test('an operation called while idle starts at once, before any microtask runs', () {
    final lifecycle = SerializedLifecycle();
    var started = false;
    lifecycle.run(() async => started = true);
    expect(started, isTrue);
  });

  testWidgets('works across a widget test\'s fake clock and runAsync', (tester) async {
    // Built in the fake zone, used from the real one: the shape of a
    // ProxyDevice that a widget test creates and then tears down in runAsync.
    final lifecycle = SerializedLifecycle();
    final result = await tester.runAsync(() => lifecycle.run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return 'done';
    }));
    expect(result, 'done');
  });
}
