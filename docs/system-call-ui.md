# System call UI preparation

The iOS target now contains a dormant APNs/PushKit/CallKit path. It registers
alert and VoIP tokens only in builds created with
`--dart-define=MESH_ENABLE_APPLE_PUSH=true`, synchronizes both tokens to the
authenticated account device, and reports a valid incoming VoIP call UUID to
CallKit before waking Flutter. Ordinary builds keep the bridge disabled and
retain the existing notification behavior.

The relay path is independently gated by `MESH_APNS_ENABLED=true` and valid
provider credentials. Message notifications use the app bundle topic; only
`call_offer` and `call_end` use `<bundle-id>.voip`. Encrypted message text is
not included in push payloads.

Before activation:

1. Configure Apple signing, Push Notifications capability and APNs provider credentials for the app bundle; keep credentials server-side.
2. Add the generated `aps-environment` entitlement through Xcode signing. Do
   not hard-code it for unsigned builds.
3. Persist a bounded pending-call/action queue across Flutter engine startup.
   Match the authenticated server call UUID and active account before
   answering. Handle expired and answered-elsewhere calls.
4. Add WebRTC audio-session handoff from `CXProvider` activation and
   deactivation, plus interruption and mute handling.
5. Enable the server variables and Flutter build flag only for a signed test
   build, then validate locked, suspended, terminated, offline, expired push,
   Focus mode, Bluetooth and competing cellular calls on real iPhones.

## Android incoming calls

Android now uses the pinned flutter_callkit_incoming 3.1.5 component for CallStyle notifications, the lock-screen answer/decline activity, self-managed Telecom registration and the ongoing incoming-call foreground service. MeshAndroidCalls unifies socket and FCM incoming presentation by call ID. Duplicate offers and recently ended IDs are suppressed; late FCM offers expire against sentTime, not when Flutter finally starts.

The native bridge caches a Flutter engine for cold push startup. Dart skips activity-only orientation and permission requests in that headless engine, restores the saved session, and consumes native actions only after matching authenticated signaling has prepared the incoming call. Opening the activity reuses the same engine and controller. No audio is captured from a push payload alone. An unanswered pending action expires and closes the native UI instead of recording indefinitely. Answer is guarded against repeated taps; a later decline/end can supersede an unacknowledged answer.

Settings > Notifications > Incoming calls on lock screen opens Android's full-screen permission settings. Notification permission is also required. Disabling notifications unregisters push as before; saved alert settings are passed to native call presentation. The ordinary notification path remains available if native presentation fails. Incoming native and Flutter ringtones do not run together once presentation is confirmed.

The plugin's receiver and presentation activity are private to the app, and its app-specific call permission is signature-protected. Keep these manifest overrides when upgrading the dependency. The native incoming dispatch uses the pinned plugin receiver synchronously to verify creation and apply the app's sound/vibration settings; retest this integration when upgrading the plugin.

This is the incoming-call integration, not a completed outgoing Telecom/hold/interruption integration. iOS CallKit above remains dormant. Neural noise suppression is a separate task. Neither Android full-screen UI nor push delivery can be guaranteed after force-stop, with denied permissions, or under restrictive vendor power management.

Before publishing, test two actual devices: locked incoming/answer/decline, caller cancellation, answer during cold startup, repeated taps, expired push, network loss during answer, logout, incoming group calls, sound/vibration off, Bluetooth and competing cellular calls. Verify caller-side cancellation too. Automated Dart tests and Android compilation do not replace this device matrix.

Reference: https://developer.apple.com/documentation/pushkit/responding-to-voip-notifications-from-pushkit
