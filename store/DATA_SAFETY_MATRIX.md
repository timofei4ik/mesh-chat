# Privacy and Data Safety matrix

| Data | Linked to account | Purpose | Shared with processor | Optional |
|---|---:|---|---:|---:|
| Login, verified email, public profile | Yes | Account and app functionality | Infrastructure/email delivery | No |
| Device/node ID and push token | Yes | Sessions, security, notifications | Push provider | No |
| Messages, comments, stories, stickers | Yes | Messaging and synchronization | Infrastructure; AI provider only when selected | No |
| Photos, video, files and voice | Yes | User-requested sharing | Infrastructure | Yes |
| Precise location | Yes | Explicit group location sharing | Map tile/provider as needed | Yes |
| Bluetooth nearby identifiers | Device-local / chat-linked | Nearby discovery and chat | No cloud unless user synchronizes content | Yes |
| Crash and performance diagnostics | No by design | Analytics and reliability | Firebase | Yes/configured |
| Subscription entitlement/reference | Yes | Paid feature access | Store/payment provider | Yes |
| IP and security logs | Potentially | Security, abuse prevention, operations | Infrastructure | No |

MeshChat does not sell data and does not use collected data for cross-app
tracking or advertising. Revalidate this table whenever an SDK or server
provider changes.
