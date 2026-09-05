# Group Audio and Shared Captions

## Implementation

- New group calls use a bounded WebRTC mesh, not the previous host-only star. The initial host invites participants; accepted guests exchange ready messages and negotiate guest-to-guest links. Lexical node ordering selects exactly one offer/restart owner per pair.
- The limit is eight invited devices, including the host. Larger group membership is rejected before microphone capture. This is not an SFU implementation.
- Guest media links are not opened while ringing. Late readiness from departed participants is ignored. Established guest links can remain when the host leaves.
- One reference-counted microphone stream is shared by local peer connections. Closing one peer does not stop other leases. Native audio-session cleanup waits for other local services to release it.
- Bounded early ICE queues retain candidates that precede the invitation or peer offer. Preparation cancellation discards late microphone acquisitions. New calls wait for the previous call's cleanup.
- The server validates current group membership for group signaling and routes group packets to exact devices instead of mixing account-device SDP responses.

## Shared Captions

- A MeshPro member can start a sponsored group-caption session. The global caption button remains absent for non-Pro accounts.
- Each other participant is offered explicit, per-call consent before their speech is sent to AI. Declining does not prevent reading captions from other speakers. Consenting participants can stop sharing their own speech and choose speech/translation languages.
- PostgreSQL stores a 90-second sponsorship lease and per-device consent. The sponsor renews every 30 seconds. Stop, expiry, subscription revocation or loss of group membership invalidates sponsored AI access. Client timers stop capture when the lease expires.
- Session identifiers reject obsolete control requests. Consent revisions prevent delayed invitation snapshots from replacing a newer approval.
- Transcription and translation requests use the authenticated sponsor's entitlement only after validating the lease and the requesting device's consent. Arbitrary AI operations cannot use this delegation. Caption publishing also requires an entitlement or a valid sponsored consent.
- Speakers retain distinct node/caption identities. Translation responses are guarded against call/language changes; receivers may request their selected language within the sponsored session.
- Live transcription results are not stored in the voice-message transcript cache.
- Live audio has a separate `ai_call_caption_seconds` allowance, derived from the existing monthly transcription-minute entitlement and accumulated across speakers. Ordinary voice-message quotas are unchanged. This intentionally avoids charging a full minute for each streaming chunk. Lifetime entitlement remains unlimited.
- Fixed the generic usage reservation's first-insert case: an amount larger than the whole allowance is rejected.

## Verification

- Complete server suite: 312 tests passed, including enabled local PostgreSQL tests, no skips. Log: `.review/group-mesh-server-complete.log`.
- Complete Flutter suite: 148 tests passed. Log: `.review/group-mesh-client-final.log`.
- Final Flutter analysis: no issues. Log: `.review/group-mesh-analyze-final.log`.
- After the final consent-revision hardening, all seven group-caption tests and the real two-worker probe were repeated successfully. Log: `.review/group-caption-consent-final.log`.
- Final two-worker PostgreSQL/Redis/WebSocket probe: `E:/meshchat-reliability-lab/group-mesh-runs/eb933239d8/result.json`. Four synthetic accounts exchanged host and guest signaling, consented on different workers, delivered captions with translations to peers, and revoked the sponsorship. Temporary test databases and namespaced Redis keys were removed.
- The probe uses synthetic SDP and caption text. It does NOT establish actual WebRTC audio, invoke a paid AI provider, or prove microphone/playback behavior on physical devices.

## Rollout and Remaining Checks

The status below records the implementation checkpoint before packaging.
Subsequent server rollout and release steps are documented in `RELEASE_1_0_95.md`.

- No production deployment, build, version bump, commit or push was performed.
- PostgreSQL migration `014_group_call_captions.sql` must run with the updated server before shipping clients. Existing migration files were not rewritten.
- The client checks the server's `group_mesh_version` before starting the new group flow. A peer answering without the new mesh capability is ended with `group_call_update_required` instead of being silently isolated from other guests. Update all test devices.
- Old incoming group invitations retain the legacy path for compatibility; they should not be used to verify the new all-to-all topology.
- Next acceptance test: three or more updated physical clients, headphones on each, alternating speakers, host departure, mute/unmute, Bluetooth routing, network change, and simultaneous speakers. Verify that a free member cannot start captions, may decline speech processing, and still sees other participants' captions.
- Large rooms require an actual SFU client/media integration and authoritative active-room admission. The existing optional SFU token endpoint is not used or enabled by this change and must not be treated as a tested room implementation.
