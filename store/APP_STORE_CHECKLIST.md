# App Store checklist

## Build

1. Create the app `com.meshchat.mobile` in App Store Connect.
2. Configure Codemagic App Store Connect integration and an App Store
   distribution certificate/profile.
3. Run the `ios_app_store` workflow. It always passes
   `MESH_DISTRIBUTION=appstore` and therefore removes Boosty and activation
   codes from the submitted binary.
4. Keep Firebase iOS variables in the encrypted Codemagic environment group.
5. Upload the IPA to TestFlight and test on a physical iPhone before review.

## App Review information

- Provide a dedicated reviewer account and invite token with populated chats,
  a group, a channel, media, reporting and account deletion available.
- Explain Bluetooth nearby chat, location sharing, calls, AI writing tools and
  that each permission is requested only when its feature is opened.
- Give the reviewer exact navigation for report, block and account deletion.
- Keep the production backend and public policy pages online for the whole
  review period.
- Use a 17+ age rating unless the final content questionnaire supports a lower
  rating; MeshChat contains unrestricted user-generated messaging.

## App Privacy answers

Use `DATA_SAFETY_MATRIX.md` as the source of truth. The bundled
`PrivacyInfo.xcprivacy` declares no tracking and covers account identifiers,
user content, media, optional precise location, crash and performance data.
Re-check the generated archive for third-party SDK manifests before upload.

## Subscription blocker

MeshPro is a digital entitlement. Apple store builds need StoreKit products,
purchase restoration and server receipt/transaction verification before the
purchase button can be enabled. External purchase links and activation codes
must remain hidden in the submitted iOS binary.
