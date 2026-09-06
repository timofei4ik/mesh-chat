# MeshChat 1.0.96+199

This release ships the native encrypted SFU group-call client. Joining an
existing room now populates participants from the initial room snapshot, so
participants present before the join are included in call lifecycle decisions.
Cancellation during encryption setup cannot start a new room after hangup.

Validation before publication:

- Flutter analysis: no issues.
- Flutter suite: 149 tests passed.
- Server unittest discovery: passed (environment-dependent tests may skip).
- Production cross-worker smoke: chat message, call offer and call end passed.
- Production LiveKit smoke: two authenticated signaling sessions joined.

The signaling smoke does not publish microphone audio and does not verify
audible E2EE playback, network handover or caption recognition on physical
devices. Those remain device acceptance checks. iOS compilation is performed
by the existing Codemagic workflow; it is not runnable on the Windows host.

The published catalog advertises build 199 only after downloadable clients and
the PWA are installed. Browser clients retain the existing mesh call route.
