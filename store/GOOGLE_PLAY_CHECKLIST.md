# Google Play checklist

## Build and signing

1. Reserve package `com.meshchat.meshchat_mobile` in Play Console.
2. Generate a private upload keystore outside Git and create
   `mobile/meshchat_mobile/android/key.properties`:

   ```properties
   storePassword=...
   keyPassword=...
   keyAlias=upload
   storeFile=C:/absolute/private/path/meshchat-upload.jks
   ```

3. Build the Play bundle from `mobile/meshchat_mobile`:

   ```powershell
   flutter build appbundle --release --dart-define=MESH_DISTRIBUTION=play
   ```

4. Verify the AAB certificate and upload it to an internal testing track first.
   Release builds reject cleartext HTTP. The direct/debug build keeps the
   current development compatibility.

The Android project targets API 36, which is the new-app/update target required
from 31 August 2026.

## Console declarations

- Complete Data Safety using `DATA_SAFETY_MATRIX.md`.
- Set the privacy-policy and account-deletion URLs from `README.md`.
- Complete content rating, app access, ads, target audience, news and health
  declarations truthfully.
- Add reviewer/test credentials and an invite token.
- Explain foreground microphone/camera/location/Bluetooth permission flows.
- Test report, block, account deletion and abuse handling on the internal track.

## Subscription blocker

MeshPro is a digital entitlement. Google Play builds need Play Billing,
purchase acknowledgement/restoration and server purchase-token verification
before store sales can be enabled. External checkout and activation codes must
remain hidden in the Play binary.
