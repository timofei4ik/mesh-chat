# MeshPro context tools

Published as 1.0.98+201 for Windows, Android and PWA on 2026-09-08 (Moscow).

## Entry points

- Chat search -> By meaning: review loaded messages in windows of 80, select context, ask a question, follow message sources.
- AI editor -> Style -> My styles: save instructions and examples, select a preset, review external processing consent.
- Message selection -> Make a plan: review selected messages, then explicitly review each proposed reminder in the existing calendar flow.
- Message menu -> AI actions: contextual reply drafts, conversation plan, or questions about a supported attachment.
- Chat menu -> Call notes: create, edit, organize with AI, save locally, or explicitly send to Saved Messages.

## Boundaries

Search is over user-selected loaded context, not an index of all historical chats. Attachment search uses filenames and existing OCR/transcriptions. Document questions support PDF text and PNG/JPEG OCR, not arbitrary visual scene analysis. PDFs are limited to 3 MB, the first 12 pages and 2,000 characters per page; scanned PDFs need OCR separately. Source buttons show extracted page text, not a full PDF viewer.

Notes and up to 20 style presets are stored per server/account in the platform secret store. Notes are limited to 50 entries. There is no automatic cross-device library synchronization. Call notes start from text the user types or pastes; calls are not automatically recorded or transcribed for this library.

Only checked sources are sent to the existing external AI provider after the explicit action. The server enforces existing MeshPro entitlements and quotas, discards unknown source IDs, refunds failed processing, and isolates PDF parsing with a subprocess timeout and Linux CPU/memory limits. Valid IDs establish source identity, not factual correctness of the generated answer. Replies never auto-send; proposed tasks never auto-create reminders.

## Verification and rollout

Flutter analyzer: clean. Full Flutter suite: 175 tests passed; focused context tests rerun after final account guards. Backend AI, PDF and command suites: 58 tests passed. Provider calls are mocked: live Groq answer quality and installed desktop/mobile UI still need an end-to-end smoke test.

Server updated with pypdf 6.18.0 and the new command registration; all 58 targeted tests passed on the host and the service health check passed. Windows, Android and PWA artifacts are in E:/meshchat-release-201, with server backups in /root/meshchat-release-201. Catalog version 46 includes release notes. Checksums, public download responses and the authenticated PWA version were verified. Android retains the previous distribution certificate and all three ABIs. No Git push or iOS build was performed in this release turn.
