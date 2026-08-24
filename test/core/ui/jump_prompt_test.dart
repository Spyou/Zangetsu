import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/jump_prompt.dart';

// The prompt exists to stop a look at another chapter/episode quietly moving
// your place — and, jumping backwards, dragging the tracker count DOWN, since
// progress is pushed as an absolute number rather than a maximum.
void main() {
  bool ask({
    required int resume,
    required int target,
    bool hasResume = true,
    bool enabled = true,
  }) => shouldAskBeforeJump(
    resumeIndex: resume,
    targetIndex: target,
    hasResume: hasResume,
    askEnabled: enabled,
  );

  test('carrying on from where you left off never asks', () {
    expect(ask(resume: 21, target: 21), isFalse);
  });

  test('skipping ahead asks', () {
    expect(ask(resume: 21, target: 39), isTrue);
    expect(ask(resume: 21, target: 22), isTrue);
  });

  test('going back to re-read asks too — that would lower the tracker count', () {
    expect(ask(resume: 21, target: 9), isTrue);
    expect(ask(resume: 21, target: 20), isTrue);
  });

  test('a title never opened has nothing to protect', () {
    expect(ask(resume: 0, target: 40, hasResume: false), isFalse);
  });

  test('turning the setting off restores the old always-move behaviour', () {
    expect(ask(resume: 21, target: 39, enabled: false), isFalse);
  });
}
