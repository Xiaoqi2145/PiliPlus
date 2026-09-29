import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => PlPlayerController.setPlayCallBack(null));

  test('no registered callback means "nothing to skip"', () {
    PlPlayerController.setPlayCallBack(null);
    expect(PlPlayerController.skipToNextIfExists(), isNull);
    expect(PlPlayerController.skipToPreviousIfExists(), isNull);
  });

  test('registered skip callbacks are forwarded exactly once', () async {
    var nextCount = 0;
    var previousCount = 0;
    PlPlayerController.setPlayCallBack(
      null,
      skipToNext: () {
        nextCount++;
        return true;
      },
      skipToPrevious: () {
        previousCount++;
        return true;
      },
    );

    final next = PlPlayerController.skipToNextIfExists();
    expect(next, isNotNull);
    await next;
    expect(nextCount, 1);

    final previous = PlPlayerController.skipToPreviousIfExists();
    expect(previous, isNotNull);
    await previous;
    expect(previousCount, 1);
  });

  test('a callback that handled nothing still reports null', () {
    PlPlayerController.setPlayCallBack(null, skipToNext: () => false);
    expect(PlPlayerController.skipToNextIfExists(), isNull);
  });

  test('re-registering without skip clears the old skip callbacks', () {
    PlPlayerController.setPlayCallBack(
      null,
      skipToNext: () => true,
      skipToPrevious: () => true,
    );

    // The live room (and every other setPlayCallBack caller) registers a bare
    // play callback. A headset "next" must then not keep switching episodes on
    // a video page further down the stack.
    PlPlayerController.setPlayCallBack(() => null);

    expect(PlPlayerController.skipToNextIfExists(), isNull);
    expect(PlPlayerController.skipToPreviousIfExists(), isNull);
  });
}
