# MeshChat Native Lab

An isolated UIKit prototype for measuring UI performance on older iPhones. It does not replace the Flutter client and does not connect to the production server.

## Included surfaces

- Reusable chat list cells.
- Reusable message bubble cells and a working local composer.
- Profile screen with a lightweight animated avatar expansion.
- FPS monitor that updates once per second.
- Automatic reduced animation in Low Power Mode and Reduce Motion.

The app targets iOS 12 and uses bundle id `com.meshchat.nativeprototype`, so it can be installed next to MeshChat.

## Codemagic

Run the `ios_native_prototype_unsigned` workflow. Its artifact is:

`ios_native_prototype/build/unsigned_ipa/MeshChatNativeLab-unsigned.ipa`

## Comparison pass

1. Cold-launch Flutter MeshChat and Native Lab in turn.
2. Scroll the chat list continuously for 30 seconds.
3. Open the same chat 15 times and scroll messages quickly.
4. Open the profile and expand/collapse the avatar 15 times.
5. Leave each app open for five minutes and compare temperature and battery use.

If Native Lab is materially smoother and cooler, migrate production screens incrementally. Authentication, sync, calls, media, and encryption remain shared contracts rather than being rewritten all at once.
