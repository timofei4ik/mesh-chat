# System call UI preparation

The dormant iOS CallKit bridge in AppDelegate and the opt-in SystemCallUi Dart adapter can report an incoming UUID, receive answer/end actions and report a remote end. They are deliberately NOT connected to the active call coordinator yet. No PushKit registration or APNs token upload is enabled. Existing notifications remain unchanged. The audio background mode allows ongoing audio sessions while the phone is locked; it does not wake a terminated app.

Before activation:

1. Configure Apple signing, Push Notifications capability and APNs provider credentials for the app bundle; keep credentials server-side.
2. Implement authenticated per-device VoIP token registration, revocation on logout, expiry and call-only APNs pushes with topic <bundle-id>.voip.
3. Add PushKit native handling that immediately reports valid incoming VoIP pushes to CallKit, before waiting for Flutter or network sync. Do not use VoIP pushes for messages or keep-alives.
4. Persist a bounded pending-call/action queue across Flutter engine startup. Match the authenticated server call UUID and active account before answering. Handle ended, expired and answered-elsewhere calls.
5. Connect SystemCallUi actions to accept/end with actual success acknowledgements. Add WebRTC RTCAudioSession handoff from CXProvider didActivate/didDeactivate, and implement mute/interruption/reset/timeout handling before enabling system call UI. Do not start audio ahead of CallKit activation.
6. Validate on signed real iPhones: locked, suspended, terminated, offline, expired push, Focus mode, Bluetooth and competing cellular calls.

## Android incoming calls

Android now uses the pinned flutter_callkit_incoming 3.1.5 component for CallStyle notifications, the lock-screen answer/decline activity, self-managed Telecom registration and the ongoing incoming-call foreground service. MeshAndroidCalls unifies socket and FCM incoming presentation by call ID. Duplicate offers and recently ended IDs are suppressed; late FCM offers expire against sentTime, not when Flutter finally starts.

The native bridge caches a Flutter engine for cold push startup. Dart skips activity-only orientation and permission requests in that headless engine, restores the saved session, and consumes native actions only after matching authenticated signaling has prepared the incoming call. Opening the activity reuses the same engine and controller. No audio is captured from a push payload alone. An unanswered pending action expires and closes the native UI instead of recording indefinitely. Answer is guarded against repeated taps; a later decline/end can supersede an unacknowledged answer.

Settings > Notifications > Incoming calls on lock screen opens Android's full-screen permission settings. Notification permission is also required. Disabling notifications unregisters push as before; saved alert settings are passed to native call presentation. The ordinary notification path remains available if native presentation fails. Incoming native and Flutter ringtones do not run together once presentation is confirmed.

The plugin's receiver and presentation activity are private to the app, and its app-specific call permission is signature-protected. Keep these manifest overrides when upgrading the dependency. The native incoming dispatch uses the pinned plugin receiver synchronously to verify creation and apply the app's sound/vibration settings; retest this integration when upgrading the plugin.

This is the incoming-call integration, not a completed outgoing Telecom/hold/interruption integration. iOS CallKit above remains dormant. Neural noise suppression is a separate task. Neither Android full-screen UI nor push delivery can be guaranteed after force-stop, with denied permissions, or under restrictive vendor power management.

Before publishing, test two actual devices: locked incoming/answer/decline, caller cancellation, answer during cold startup, repeated taps, expired push, network loss during answer, logout, incoming group calls, sound/vibration off, Bluetooth and competing cellular calls. Verify caller-side cancellation too. Automated Dart tests and Android compilation do not replace this device matrix.

Reference: https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit
