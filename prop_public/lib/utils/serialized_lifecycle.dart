/// Runs operations one at a time, in call order, so two un-awaited lifecycle
/// calls (start, stop, restart) can never interleave. A failing operation
/// fails its own future only; the next one still runs.
///
/// An operation called while nothing is pending starts at once, in the
/// caller's own zone: queueing it behind an already-completed future would
/// make it wait for a microtask of whichever zone created that future, which
/// never runs when that zone is a test's fake clock.
class SerializedLifecycle {
  Future<void>? _last;

  Future<T> run<T>(Future<T> Function() op) {
    final previous = _last;
    final result = previous == null ? Future<T>.sync(op) : previous.then((_) => op());
    final done = result.then<void>((_) {}, onError: (Object _) {});
    _last = done;
    done.whenComplete(() {
      if (identical(_last, done)) _last = null;
    });
    return result;
  }
}
