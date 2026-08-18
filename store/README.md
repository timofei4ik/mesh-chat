# MeshChat store release

The direct MeshHub build and store builds are intentionally different:

- `direct` may show activation codes and Boosty links;
- `appstore` hides every external purchase and activation path;
- `play` hides every external purchase and activation path.

Never submit a default/direct build to Apple or Google.

## Public URLs

- Privacy: https://meshchat-losa.ru/meshpro/legal/privacy
- Terms: https://meshchat-losa.ru/meshpro/legal/terms
- Community Guidelines: https://meshchat-losa.ru/meshpro/legal/community
- Support: https://meshchat-losa.ru/meshpro/legal/support
- Account deletion: https://meshchat-losa.ru/meshpro/legal/account-deletion
- Moderation console: https://meshchat-losa.ru/admin/moderation/

## Remaining account-gated work

The codebase is prepared for store-safe distributions, but paid MeshPro sales in
store builds must remain unavailable until products are created in App Store
Connect and Play Console and StoreKit / Play Billing receipt verification is
implemented server-side. Do not enable external checkout in those builds.

The developer accounts are also required to create signing certificates,
provisioning profiles, an Android upload key, store listings, age ratings,
privacy questionnaires, tester groups and the final submissions.
