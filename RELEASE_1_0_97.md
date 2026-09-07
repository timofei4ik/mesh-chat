# MeshChat 1.0.97+200

## Changes

- Eighteen illustrated bubble styles with fixed-size artwork at the upper and
  lower right edges. Tall messages do not stretch the scenery.
- Chat appearance now offers actual bubble previews, automatic profile matching
  and an option without artwork. The animated-background toggle remains available.
- The explicit bubble selection applies to the sender's messages in every chat,
  independently of their profile background. Updated recipients do not need MeshPro
  to see it. Selection is server-gated by `custom_message_bubbles` and stored by
  authenticated account, not by client-supplied login.
- Shared linear page transitions, edge-swipe back navigation and painted bottom
  sheets. Updated chat previews, reply quotes, transcripts and attachment menu.
- Slower background motion and off-main-isolate media encoding/cache preparation.

## Rollout

Use existing staging `E:\mc198`, Pub cache `E:\meshchat_pub_cache`, Gradle cache
`D:\meshchat-build-cache` and temp `E:\meshchat_build_temp`. Do not clean caches.
Artifacts are in `E:\meshchat-release-200`. Build Windows, APK and web with the
existing Firebase defines. Verify APK signature against the preceding release.

Server migration 016 is additive: `account_bubble_appearance(login, style)`.
The account-deletion owner removes this preference when the account is deleted.
Existing clients ignore the new public-profile field and remain compatible.
Subscription expiry hides the decoration without deleting the saved selection.

Server release directory: `/root/meshchat-release-200`. Preserve the verified
PostgreSQL backup and `server-before.tar.gz`. Roll back code only if necessary;
do not restore a database over newer user messages. The additive table may remain.

Publish all packages before replacing `apps.json`. Preserve cookie access rules,
Nginx configuration and unrelated website/download files. MeshHub release notes
are delivered through the same catalog; no MeshHub rebuild is needed.

## Verification

- Flutter analyzer: no issues.
- Server: 77 subscription, account-deletion, command and sync integration tests.
- Widget tests cover independent style selection, serialization, preview layout,
  failed saves, all collection dimensions and tall-message rendering.
- Physical iPhone interaction and cross-device visual acceptance still require
  device testing. Codemagic builds iOS from the published Git source.
