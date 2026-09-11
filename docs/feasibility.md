# Feasibility notes — 11 September 2026

## Evaluated sources

Sources inspected for the implementation; separate live results appear below:

- [mautrix/gmessages](https://github.com/mautrix/gmessages/tree/b0d61b4e1a4e94f0d5e6fedd43cadb80bd0a9e51), pinned at `b0d61b4e1a4e94f0d5e6fedd43cadb80bd0a9e51` (`v0.2608.1-0.20260910090721-b0d61b4e1a4e`).
- [OpenMessage](https://github.com/MaxGhenis/openmessage/tree/c7d7445474ec75662659377da984cb862c62fca0), inspected at `c7d7445474ec75662659377da984cb862c62fca0`.
- [Google's linking requirements](https://support.google.com/messages/answer/7611075?hl=en) and [mautrix account authentication instructions](https://docs.mau.fi/bridges/go/gmessages/authentication.html).

## Decision for the experiment

Use upstream `libgm` in a small read-only probe. This isolates the key questions—pairing, one-year history and originals—without adopting OpenMessage's broader WhatsApp/Signal/MCP stack. OpenMessage remains a candidate for reuse or contribution; it has not been rejected or benchmarked here.

OpenMessage's inspected Mac interface wraps its own locally served interface rather than Google's web app. It already contains substantial storage, messaging and repair work. Its Go module uses a fork of `gmessages` exposing conversation pagination. It is a useful reference for the future application and that missing upstream interface.

## Confirmed in source

1. `pkg/libgm` is importable independently of the Matrix connector. No Matrix server is required for this probe.
2. The current upstream constructor takes HTTP client settings, and message methods accept contexts; the inspected OpenMessage fork has older call signatures. The probe compiles against the actual pinned upstream API.
3. `FetchMessages` accepts a cursor; protobuf message timestamps are microseconds. The upstream connector converts cursor timestamps to milliseconds and synthesises an oldest-message cursor when a response omits one. The probe follows those units without subtracting time, and deduplicates overlapping IDs.
4. `ListConversationsRequest` contains a cursor field in the schema, but the current upstream public `ListConversations` method does not accept a cursor. Thus the probe cannot prove complete conversation enumeration.
5. A message can contain multiple `MessageInfo` media entries. The archive handles each entry, rather than keeping only the first attachment.
6. Downloading an original and displaying a thumbnail are separate outcomes. Missing original IDs/keys must be shown explicitly. The full-size-image request returns an empty acknowledgement; the resolver waits for an attachment update in the normal message stream. Its routing and timeout behaviour are tested with synthetic events. Real JPEG and PNG attachment downloads have also succeeded, although some requests failed. An attachment original is the file Google Messages supplies, not a claim of original camera resolution.
7. Account authentication uses Google session cookies and phone confirmation. The native helper is a feasibility implementation; sign-in succeeded on the tested account, but compatibility with other accounts remains unknown.

## What the experiment does not prove

- That pairing remains usable after cookie expiry. Initial Google sign-in, phone emoji confirmation, Keychain persistence and a subsequent read-only phone request succeeded on the user's Mac and Pixel.
- That the source returns all of the last year's conversations, messages or media.
- That remote RCS semantics, delivery receipts or notification timing match the phone.
- That the finite importer can be used as an always-on sync engine. Live events, durable queues, reconciliation and credential renewal remain necessary.
- That downloaded archives provide application-level encryption or production backup semantics.
- That the native Google sign-in UI works for other accounts or is appropriate for App Store distribution.

## First live validation

- Account sign-in and emoji confirmation succeeded. The session was saved in Keychain and loaded for a subsequent connection.
- Fixed a readiness bug: the current library retains the `ClientReady` type but no longer emits it. Startup now validates a read-only `IsBugleDefault` round trip, with cancellation and failure cleanup covered by regression tests.
- The first inbox-listing request timed out, while the next archived-conversation request succeeded. A bounded retry now handles read timeouts within the same session. The first upstream request uses `BUGLE_ANNOTATION`; subsequent calls use an ordinary message type. This is a possible explanation, not a confirmed root cause.
- Archived-conversation history requests returned valid timestamps, but the threads examined were older than the requested year. The importer now skips conversations whose known last-message timestamp is before the cutoff; missing/invalid activity dates still require a history fetch.
- The first completed text import stored 3,984 messages across 228 conversations, spanning 11 September 2025 to 10 September 2026 UTC. Transport projections were 3,166 SMS, 107 MMS, 708 RCS and three unknown. These are local snapshot counts, not proof of complete phone coverage.
- The source returned 279 inbox and 105 archived conversations. Of those 384, 119 crossed the requested date boundary, 109 exhausted the returned message history and 156 had a latest-message timestamp before the cutoff. No returned conversation remained in a failed or page-limited history state.
- SQLite's integrity check passed, and a local full-text query returned results without contacting Google. Full-size image resolution has succeeded for older attachments whose initial history metadata lacked a download reference. Sparse history refreshes now preserve those downloaded-file references, with a regression test for both missing metadata and explicit media replacement.
- The photo pass saved 64 attachment originals (22,117,650 bytes). All 64 files were present, had valid dimensions according to macOS image tooling and had user-only permissions. This was metadata validation, not a visual comparison with the phone.
- That photo pass was partial: 21 image requests failed and 54 more image records remained unattempted when three consecutive timeouts stopped the pass. A second pass with a one-minute wait per request also stopped after three consecutive timeouts without recovering additional images. These failures did not establish that the phone's files were missing; subsequent recovery is recorded below.

## Photo recovery investigation

- Fresh history lookups for three previously failed MMS PNG attachments returned valid original download IDs and keys. Their archived descriptors were stale; simply waiting longer for another live update did not recover them.
- The media pass now refreshes missing references before making full-size requests and rechecks history after a request timeout. It preserves the text snapshot, completed history checkpoints and existing downloaded-file references. Lookup scans are bounded independently of history coverage.
- The previous receiver ignored events with no active waiter and returned after handling one attachment. It now retains original references for all parts, including late updates, in a bounded cache keyed by message and attachment. This removes an identified loss path; the exact timing of earlier missed updates was not recorded.
- Regression tests cover stale-reference recovery, pagination, unchanged text/checkpoints, media filters and budgets, late and sibling updates, cache bounds and acknowledgement-only timeouts. The race detector and vet checks pass.
- The corrected live pass recovered 37 original references during its initial metadata refresh and then finished downloading **all 139 image attachments in the current archive**, adding 75 originals. No image records remain failed or pending. Nineteen non-image attachments were excluded by the photos-only filter.
- Final validation found all 139 files present (60,554,649 bytes), with user-only permissions. macOS ImageIO successfully decoded all 376 image frames, including animated media. SQLite's integrity check passed; the archive still contains 3,984 messages, and the local CLI search returned the same 19 matches with media keys omitted. This verifies the returned archive's files, not independent completeness against the phone's entire inbox.

## Next decisions driven by the Pixel test

1. Improve the successful pairing flow's rough configuration-text screen and add credential renewal; evaluate browser-assisted sign-in if embedded sign-in becomes incompatible.
2. Verify a recent SMS thread, a recent RCS thread, an archived thread and a busy year-long thread; compare dates and available originals.
3. Add/submit conversation pagination upstream or adopt the smallest maintained compatible patch if inventory is truncated.
4. Once archive/search feasibility is established, choose whether to reuse OpenMessage's backend or build the production sync layer around `libgm`.
5. Extend the native archive viewer with continuous sync, sending, uploads, reaction actions, notifications, then typing indicators. RCS groups and iOS remain lower priority.

## Native archive viewer validation

- Built a macOS 14+ SwiftUI app, Local Messages, using the existing SQLite archive. Database work runs in an actor; thumbnails are downsampled off the UI thread and held in a bounded cache. The app makes no Google or Keychain requests.
- Verified the interface with synthetic data: conversation selection, latest-message positioning, older-history loading, global search, jumping to a result outside the latest page, archived/empty conversations, keyboard search, reply display and photo previews in Quick Look. A synthetic message inserted while the viewer was open appeared after a local reload.
- Native database checks cover pagination without missing/duplicate rows, search scope and punctuation, old-message context, empty histories, rejected writes and attachment path/symlink escapes. The synthetic fixture uses WAL mode like the real archive.
- Apple's SQLite on this Mac could not open a WAL database with a read-only handle when the importer had removed its journal helper files. The viewer permits SQLite to initialise these files, then applies query-only mode and an authorizer denying data, schema and settings changes. FTS5's read-only `data_version` check is permitted. SQLite's [WAL documentation](https://www.sqlite.org/wal.html#read_only_databases) explains the journal/shared-memory requirements. No immutable-file shortcut is used, so the viewer can observe later imports after reloading.
- Opened the live archive in the native app and verified its displayed totals: 3,984 messages and 139 photos, with a conversation loaded and no read error. Live message contents and photo screenshots were not included in the validation output.
- This is still an archive viewer. Continuous sync, sending, uploads, reaction actions and notifications are not implemented; archive completeness against the phone remains a separate acceptance check.


## Background receiving milestone (2026-09-11)

The native app now owns a Go `watch` process when a paired live archive is open. Status-only JSON lines travel through stdout; message data travels through local SQLite. The connection starts before observer-driven catch-up, live events invalidate conversation ranges rather than applying potentially stale replay payloads, and each conversation has a separate durable catch-up watermark. Photo downloads run separately from text updates and merge attachment fields into the latest row.

Automated checks cover partial catch-up/retry without gaps, unchanged historical cursors, repeated/malformed pages, old-reaction refresh boundaries, concurrent event coalescing, bounded queue overflow, transient connection retry, logout/Keychain terminal states, status privacy, and shutdown with an active photo task. Native tests and a synthetic UI session verified automatic search/count updates, edit/reaction refresh without moving an old search result, and explicit navigation to a newly arrived message.

The first live worker test completed phone readiness and exited cleanly when its parent pipe closed after 90 seconds. A longer run reached connected after approximately 168 seconds, established 37 conversation catch-up checkpoints, and increased the saved message count from 3,984 to 3,985. SQLite integrity remained valid. The app then showed the live archive and connection progress; pausing reduced the sync-worker count to zero, and resuming reused the saved pairing. No messages were sent or marked read during testing. Physical sleep/wake recovery still needs extended device testing.

Remaining sync limits: bounded inbox/archive listings; incomplete deletion/folder-removal reconciliation; no exhaustive offline edit audit for old conversations; no receiving while the Mac is asleep or the app is closed; periodic original-photo batches with no total disk quota; upstream protocol reliability and credential-renewal UI still require hardening.


## Text composer and notifications (2026-09-11)

Text sending now uses explicit JSON commands over the app-owned worker's private stdin pipe. A random connection token binds commands to the current session; outbox reservations commit before preflight and wire submission. Duplicate attempt IDs, process restarts and ambiguous timeouts never trigger an automatic resend. Fresh conversation metadata and matching SIM settings are required; no recipient, participant or SIM is guessed. Outgoing temporary IDs reconcile accepted/unconfirmed attempts with archived phone messages. The send request shape follows the pinned upstream connector's text payload, while automatic retry is deliberately omitted.

Go tests cover exact Unicode payloads, routing, read-only/mismatched conversations, durable-before-send ordering, duplicate/restart suppression, definite rejection, ambiguous timeout, stale connection tokens, crash recovery and outgoing echo reconciliation. Swift checks cover persisted drafts, stale-save suppression, private file permissions, outbox states, incoming journal queries and notification eligibility. Native UI checks verified multiline Return behavior, draft separation across conversations, draft restoration after restart, and disabled sending for synthetic archives.

A read-only live probe performed send preflight for three recent inbox conversations, discarding every returned send closure without invocation. Two produced valid routing payloads; one was unavailable for sending. No recipient message was submitted by these tests. Real SMS/RCS delivery and receipts from the composer still need an explicit live send test.

The development Mac registered a notification permission prompt and later recorded authorization as denied. The app reports that state and provides a macOS Notifications settings link. Notification code and filtering are implemented, with previews hidden by default; banner delivery and notification-click routing have not been verified with granted permission.

## Shared contacts and granted notification permission (2026-09-11)

The shared-contact placeholder was caused by the app's photos-only filter. Version 0.3.1 downloads photos and contact cards automatically. The CLI retains its photos default and adds `contacts` and `photos-and-contacts`. Metadata recovery and downloading share one selection policy; vCard MIME names are case-insensitive, parameters are ignored, and `.vcf` filenames cover generic MIME metadata. Saved originals use `.vcf` rather than `.bin`.

A bounded local preview uses `CNContactVCardSerialization`, supports multiple contacts, Unicode, folded lines, phone numbers, email/postal addresses and websites, and provides selectable text. It does not query/write the address book or load remote images. The user can explicitly open the original in macOS Contacts or reveal it in Finder. Invalid files and preview limits (4 MiB / 100 contacts) have explicit error states.

Go race tests/vet and native checks passed. Tests cover contact selection, retained photos-only behavior, metadata recovery, excluded audio/files, budgets, MIME casing/parameters, filename fallback, Unicode/escaped punctuation, folded lines, multiple contacts, malformed input and oversized files. The native preview was visually checked using fictional details. The live recovery refreshed five missing original references and saved all six vCards. Apple's parser read seven contacts with contact details from those six files; no private fields were logged. All files have user-only permissions and SQLite integrity passed. The archive remains at 3,985 messages, with 139 photos and six contact files saved locally.

The user enabled macOS notification permission. The app's separate toggle is now enabled too, and permission refreshes when the app becomes active after Settings. A local test reached Notification Center and was stored in history. System logs showed banner/sound suppression because the display was considered shared during the UI test, rather than a permission denial. An unsuppressed banner, real incoming-message click routing and SMS/RCS delivery remain live acceptance checks. No messages were sent by this validation.

## User review improvements — version 0.4.0 (2026-09-11)

The user successfully sent a real SMS and received a reply. They observed delayed confirmation in the Mac app and a reply hidden behind the latest-messages button. The worker previously serialized urgent refreshes behind inventory/history work; fresh events and recent send attempts now have a separate priority refresh loop, with per-conversation locks to prevent stale snapshots overwriting newer data. A regression test saves an incoming reply while the inventory request is deliberately blocked. This removes an identified source of delay; end-to-end confirmation latency against the Pixel has not yet been measured after the change.

The native timeline now follows incoming replies while positioned at the latest messages, preserving the position when browsing older history or a search result. Notification suppression checks whether the new message is actually visible in the active conversation; Settings also permits notifications while viewing that conversation. macOS Focus and display-sharing rules can still suppress banners independently of permission.

The conversation toolbar provides expandable thread search, separate from the sidebar's global search. Fresh conversation metadata supplies participants and phone numbers. Clicking the name or information button opens contact details and local Photos, Links and Files tabs. The library starts with 300 recent messages and can scan further back. HTTP(S) links are extracted locally without fetching previews. Existing shared-contact previews remain available.

Settings provides system/light/dark appearance and per-archive history dates. Earlier history resumes in bounded pages alongside live receiving. Optional age-based cleanup is disabled by default and only removes local records/files. Pending or ambiguous sends are protected, shared media references are checked before file deletion, and a persistent cleanup queue handles interrupted or late downloads. Regression tests cover search-index removal, shared media, late old snapshots, late file completion and restoring older history after disabling cleanup. No cleanup or custom history setting was applied to the live archive during validation.

The composer now stages selected attachments privately on disk and persists them with the draft. Sending verifies the staged bytes and uses the pinned connector's encrypted media upload followed by one message submission. The initial cap is ten files and 25 MiB combined; phone/carrier restrictions may be lower. Reaction actions support adding, switching and removing the user's own reaction using fresh conversation routing. Both use durable attempt IDs and preserve ambiguous results without automatic resubmission. Receiving still downloads photos and contact cards automatically; other file types can remain metadata-only.

Go race tests/vet, native archive checks and the complete app build passed. Synthetic UI checks verified automatic arrivals, preservation of older search context, scoped search, phone details, photo Quick Look, link navigation, dark mode, saved history preferences, and attachment selection/draft restoration across restart. Validation did not send a message, upload a file or submit a reaction to a real recipient. Real attachment/reaction delivery, RCS sending and unsuppressed incoming notification banners remain device acceptance checks.

The app was restored to the paired live archive with one background sync worker. A read-only check found 384 conversations, 3,987 messages and 139 images; SQLite integrity passed. The user's SMS/reply increased the saved total from the earlier 3,985-message snapshot. Private message contents and contact details were not included in validation output.

## Focus, reaction presentation and quick navigation — version 0.4.1 (2026-09-11)

The user confirmed real reaction actions work and reported much smoother, faster sending after the priority refresh change. They selected a history start of 11 September 2021 with retention disabled. During this pass, the live archive grew from 3,988 to 6,463 messages, with 38 conversations recording completed coverage of the requested range; SQLite integrity passed. The five-year import is progressing, not yet verified complete against the phone.

Thread search defers its focus request until the field is mounted, and the composer relinquishes focus. Reaction badges overlap the bubble's lower-right edge with space reserved above the timestamp; short messages expand enough to fit their badges. Outgoing messages retain received badges but omit both reaction actions. Floating navigation returns the conversation list to the top or a thread to its latest messages. macOS 15+ uses scroll geometry to show shortcuts only away from the relevant edge; macOS 14 keeps the list shortcut available for longer lists. Timeline refresh applies incoming rows, outbox and the scroll request together so a larger content height cannot cancel an existing follow-latest intent.

Synthetic UI validation checked typing immediately after toolbar search/Command-F, badge placement on photos and short incoming/outgoing bubbles, scrolling a long conversation list and returning to the top, jumping to the latest message, following fresh arrivals, and preserving older history until explicitly jumping forward. Native archive checks passed. No real messages or reaction actions were submitted during validation.

The image-attachment error is generated during local staging. A local synthetic PNG attached successfully through the native file picker, so the exact user failure remains unconfirmed without the original file/path. Staging now uses fstat on the opened descriptor instead of potentially stale URL resource values, reads in bounded chunks until EOF, and preserves the byte limit and fingerprint. Storage containment compares canonical paths instead of URL identity. Errors distinguish unreadable, empty, changing, oversized and invalid-name files from archive storage failures; selecting files clears a previous error. Regression checks preserve exact photo bytes despite cached zero-size/non-file picker metadata and reject an oversized file. These repairs cover identifiable failure paths but are not evidence of recipient-side attachment delivery.

Version 0.4.1 (build 6) was built and reopened on the live archive with one sync worker. The saved history start remained 2021-09-11 and retention remained off. At restart the archive contained 7,402 messages and passed SQLite integrity validation; the import still had work remaining. The isolated UI test app was closed.

## Archive size and account lifecycle — version 0.4.2 (2026-09-11)

Settings now measures the open archive's approximate allocated disk space, with available drive capacity and a database/media/drafts/working-files/other breakdown. An actor enumerates metadata without opening message or image contents, excludes symlinks, reports partial measurements and handles macOS path aliases. Measurement refreshes every 30 seconds while the pane is open and on explicit refresh. It measures the existing archive, not future import size, backups or the application bundle.

Native checks cover categories including hidden working files, new-download growth, excluded external/cyclic symlinks and temporary-directory aliases. A synthetic Settings session verified the layout, expandable categories and a manual refresh after adding a 1 MiB file: the total rose from 279 KB to 1.3 MB, with the increase in downloaded media. Retention stayed off. A read-only live scan returned 74,674,176 allocated bytes across an archive containing 14,234 messages; no incomplete measurement was reported.

Account-lifecycle inspection confirmed that Google logout cancels sync and emits `pairing_required`, without deleting local data. Ordinary app reopening and network reconnect reuse the path-associated Keychain pairing. Both the CLI's nonempty-archive check and the pairing client's existing-Keychain check intentionally block re-pairing in place. Automatic same-account relinking, account switching and an explicit sign-out/delete-local-data interface are not implemented. These facts were checked in code; the user's pairing was not revoked for a live experiment.
