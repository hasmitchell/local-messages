# Google Messages for Mac — feasibility prototype

A native Mac client prototype with local storage, search and background receiving, text replies and notification support. The initial target is the past year of messages and photos from Google Messages on a Pixel 10 Pro. This is **not yet a replacement messaging app**.

The [product brief](docs/product-brief.md) records the requirements. The [research notes](docs/feasibility.md) explain the library choice and unresolved questions.

## What exists

- A native Google sign-in window and a Google-account/emoji pairing command.
- Pairing credentials stored in macOS Keychain, passed through private process pipes.
- A read-only Google Messages history adapter using a pinned upstream `libgm` dependency.
- SQLite storage and FTS5 full-text search, usable without network access after import.
- An inclusive one-year default history cutoff, atomic page checkpoints, resume support and duplicate prevention.
- Text, sender, transport/status, reply references, reaction metadata and multiple attachment descriptors.
- Optional original-media downloads, with explicit unavailable/failed/budget-limited states.
- A synthetic demo that does not connect to Google.
- A native SwiftUI Mac app for browsing conversations, reading saved history, searching and previewing downloaded photos.
- Background receiving while the app is open, automatic catch-up/reconnect, pause/resume, and incremental search updates.
- A multiline composer with photo/file attachments for existing conversations, local drafts and a durable outbox.
- Native notification controls, hidden previews by default, and filtering for fresh incoming messages.
- Automatic downloads and native previews for shared vCard contacts, including cards containing multiple people.
- Separate global and in-conversation search; phone numbers and per-thread photos, links and files.
- Add, replace and remove your reactions from the message menu.
- Light/dark/system appearance, a custom history start date, and optional local retention (off by default).

Native helper and Go probe compile on this Apple Silicon Mac. Archive/history tests pass, including the race detector. **Google sign-in, emoji pairing, Keychain persistence, a one-year history import, local search and full-size image retrieval have been verified on the user's Pixel.** The first snapshot contains 3,984 messages and 139 image attachments; all 139 images are now downloaded and decode successfully, after recovering stale attachment references. Complete conversation inventory remains unverified. Google sign-in compatibility on other accounts remains unverified; this is not a supported OAuth flow.

The user has successfully sent an SMS from the composer, received a reply and used reactions. They report noticeably faster send confirmation with version 0.4. Attachment delivery and RCS sending still need device testing. Typing indicators and production sync hardening remain subsequent milestones.

## Open the Mac app

```sh
./scripts/build-app
./scripts/messages-app
```

This builds **Local Messages.app** in `build/` and opens the existing live archive. The app bundles the Go sync worker and copies the existing Keychain helper without recompiling it. The build compiles that helper only if it is missing. You can also open the app from Finder, or pass another archive directory to `./scripts/messages-app /path/to/archive` when the app is closed.

- The sidebar lists **Inbox** or **Archived** conversations with contact photos (fetched from the phone's contacts when available, otherwise initials), relative dates, two-line previews, an unread marker and any unsent draft. A conversation counts as unread while the phone reports it unread and it has not been opened here; the Dock icon shows the count. Opening a conversation's newest messages here also marks it read on the phone (a best-effort `mark_read` request, on by default in General settings; turn it off to keep reading here invisible to the phone). Reading on the phone clears the marker here within seconds: the worker applies the phone's conversation updates as they arrive instead of waiting for the next sweep, ignoring any update that refers to older activity than the archive already holds.
- Read the latest 100 messages, then show earlier history as needed. Consecutive messages from one sender are grouped; time labels appear on day changes or after an hour's gap. Hover over a bubble for its exact time, transport (SMS/MMS/RCS) and delivery state; the latest outgoing message always shows its status. Replies quote the original message, saved reactions attach to the bubble, and web links are clickable.
- The search field at the top of the sidebar searches conversation names, numbers and message text across the archive, with matching terms highlighted. The toolbar's find field (**⌘F**) searches the open conversation and lists matches in a panel beneath it; **Esc** closes it. Results open the matching message in context, including older history.
- Click a downloaded photo or file for native Quick Look. Shared `.vcf` contacts open a local preview with selectable phone numbers, email and postal addresses. **Add to Contacts** saves the card into macOS Contacts after you grant Contacts access; when the Mac has a Google account with Contacts enabled (System Settings → Internet Accounts), **Add to Google Contacts** saves into that account so the person reaches Google Contacts and the phone. **Open in Contacts…** hands the file to the Contacts app instead. Previewing alone does not import anyone. The context menu can reveal the original in Finder.
- **⌘F** finds in the open conversation, **⌘⇧F** focuses the sidebar search (macOS 15 or later), **⌘I** shows the contact details, **⌘J** jumps to the latest message, **⌘,** opens Settings, **⌘O** opens another archive, and **⌘R** reloads it. The **Conversation** menu lists these.
- The sidebar's status bar shows the connection state, message and photo counts and the newest saved date. Its **⋯** menu can pause, resume or reconnect sync and reload the archive.
- New messages appear and scroll into view automatically when you are at the bottom. While browsing older history or a highlighted result, the reading position stays put. A floating down-arrow jumps to the latest messages; the conversation list offers **Back to top** after scrolling down. On macOS 14, the list shortcut stays available for lists longer than eight conversations.
- Click the contact's photo in the toolbar (or press **⌘I**) for a details popover with the saved numbers and the conversation's **Photos**, **Links** and **Files** library. Shared items link back to their original messages; libraries initially scan 300 saved messages and offer more history when needed. Website previews are not fetched.

Opening a paired live archive starts a background worker that connects to Google using the existing Keychain pairing. Saved history and search remain usable offline. Synthetic/demo archives never start a Google connection. The account menu in the sidebar toolbar switches between saved accounts and opens Settings. **Add Account…** pairs another Google account into a separate archive; **Manage Accounts…** lets you rename entries and continue unfinished setup. Only the selected account syncs and shows notifications. Switching back reopens its local history, drafts and history/storage settings, then catches up using its saved pairing. Normal app launches remember the last open account.

Press **Return** (or **⌘Return**, or the Send button) to send; **Shift-Return** adds a new line. While an input method is composing, Return confirms the composition instead of sending. **New Message** (the sidebar's pencil button or **⌘N**) starts a conversation with one of your phone's contacts or a typed number: the phone resolves it to an existing thread or creates one, and the app opens it for composing. The contact list is fetched from the phone once a day. Include the country code for numbers outside the phone's region. Right-click a message and choose **Reply** to quote it (RCS). The composer checks spelling while you type; automatic correction is off unless enabled in General settings. The smiley button opens macOS **Emoji & Symbols** (also **⌃⌘Space**). Common standalone emoticons such as `:)`, `;)`, `:D` and `<3` turn into emoji as you type; Undo restores the emoticon, and General settings can disable conversion. Pasted text and input-method composition are left intact. Files dropped anywhere on the conversation, or pasted with ⌘V (files from Finder, or an image such as a screenshot), are staged as attachments. Non-downloaded attachments show an explicit placeholder, and threads outside the saved date range have an empty-history explanation.

Typing updates the composer independently of the conversation list and timeline. Draft saves and sidebar previews update after a short pause, and normal quit waits for pending saves. Selecting a conversation updates its header and loading state immediately; a separate read-only database connection fetches its messages without waiting behind background archive summaries.

Archive queries run off the UI thread. SQLite uses query-only mode and an authorizer that rejects data/schema changes. On this Mac, a writable SQLite handle is needed to initialise missing WAL/SHM journal helper files; this does not grant the app's queries permission to edit messages. Thumbnails use a bounded memory cache, and file previews only resolve paths inside the archive's media directory. The last selected archive path is remembered in local app preferences.

The app targets macOS 14 or later and has been built on the development Mac. Run its synthetic checks with:

```sh
./scripts/test-app
```

These checks cover history paging, search and result context, archived/empty threads, rejected database writes, unsafe attachment paths, shared-contact parsing, updates from a separate writer, and preserving the visible history range. They create a temporary synthetic fixture under `.cache/`.

To look at the interface without opening a real archive, render it on the synthetic fixture:

```sh
./scripts/snapshot-app main search inspector settings dark
```

This builds a separate review bundle (`build/review/`, its own preferences domain) that includes a snapshot hook compiled only with `-D UI_SNAPSHOTS`, and writes PNG files to `.cache/review-shots/`. It needs no screen-recording permission because the app renders its own windows. The review bundle opts out of macOS 26 glass rendering so the sidebar and inspector are captured; the product bundle does not.

## Composing and notifications

Choose a conversation, or start one from a phone number with **⌘N**, and type in the composer. **Return**, **⌘Return** or the arrow button sends; **Shift-Return** adds a line. Each conversation keeps its draft across switching and restarts, under a user-only `drafts/` directory inside the archive. The phone supplies the current outgoing participant and SIM; unavailable or read-only conversations fail before submission. SMS/RCS selection follows the phone's settings. A new-conversation request is a durable `start` command: the worker records it in the outbox, asks the phone for the conversation belonging to the number, saves the returned thread and marks the attempt resolved, failed or offline. Repeating an attempt ID never asks the phone twice; the app waits up to a minute for an answer. Group creation is not offered.

The paperclip, a drag-and-drop or a paste selects photos or files. Files are copied into a private local staging folder and listed in the draft; remove a chip to exclude it. Selecting a file does not upload or send it. A draft can contain up to ten files and 25 MiB in total, with optional text. These are prototype limits; the phone/carrier may reject smaller files or unsupported formats. The worker verifies file sizes, fingerprints and confined paths, then encrypts/uploads using the pinned library only after an explicit Send. Upload failures before message submission are reported as not sent; an uncertain submission is never automatically repeated. Failed messages can restore both their text and attachments as a draft.

While the other side types, three dots appear at the end of the conversation and the sidebar row says "Typing…"; your own typing is relayed to the phone at most every four seconds while sync is connected. Hover over an incoming message and use the smiley button beside it, or right-click **React**, to choose a reaction. Your own outgoing messages show received reactions but have no reaction action. Reaction badges overlap the bubble's lower-right edge. An existing reaction from your phone account is replaced; **Remove My Reaction** removes only your saved reaction. Actions require current conversation/SIM routing, use the private command pipe and durable outbox, and trigger a priority refresh. Reaction timeouts remain unconfirmed instead of being silently retried. SMS reaction behavior follows Google Messages and the recipient's transport capabilities.

A send attempt is committed to the local outbox before any network submission. Each attempt has one UUID and one network attempt. An acknowledgement means **accepted by the phone**, not delivered to the recipient; subsequent phone messages supply sent/delivered/read status. Connection loss after submission produces **Send unconfirmed**. There is no automatic resend, including after restart. Check the phone before composing the same message again. A known failure can be restored as a draft. Pending states survive restarts and reconcile with the outgoing message's temporary ID.

Sending keeps the conversation on screen and shows a pending bubble immediately, with a short entrance and a bounce on the Send button. The saved draft remains protected until the worker acknowledges it. Confirmation updates the same bubble instead of inserting it a second time; it does not replay the animation. Sending from older history reveals the latest page without blanking the conversation, and manual scrolling takes over from automatic following. macOS Reduce Motion uses a brief fade without the bounce or animated scrolling.

If the app loses contact with its worker before an outbox acknowledgement, the draft and attempt ID remain saved. Pause sync and use **Check saved send status** to recover an attempt only after the worker is stopped and no outbox record exists.

Message notifications carry a **Reply** field: text entered there goes through the same outbox path as the composer, and a second notification reports a reply the phone connection could not take. **Settings → Notifications** controls desktop notifications and optional message previews. Previews default to hidden, so the banner says only that a new message arrived. Notifications require macOS permission; when blocked, the menu offers a settings link. **Show Test Notification** creates a local test after permission is granted. Notifications only operate while the app is open and receiving.

An insertion journal avoids alerts for message edits, replay and photo updates. The app ignores messages older than the current archive-opening time, stale catch-up messages more than five minutes old, and outgoing messages. Foreground suppression now requires the incoming message to be loaded at the latest visible edge; selecting a conversation alone is not enough. Settings offers **Notify while viewing the conversation** if you also want those alerts. Selecting a message notification opens its saved conversation. Historical imports do not produce a notification flood.

## History, appearance and storage settings

**⌘,** or the account menu's **Settings…** opens the Settings window with **General**, **Notifications**, **Connection** and **History & Storage** tabs. Appearance follows macOS by default; Light and Dark apply immediately. History/storage changes apply to the open archive after **Apply**. Choose a custom date, past year, past five years, or all available history (requested from 2000). An earlier start triggers resumable background backfill; a later date does not delete existing local copies. Conversation inventory and upstream history availability remain limits on completeness.

**Local storage** shows the current archive's approximate size on disk and space available on its drive. Expand **Storage breakdown** for the message database, photos/downloaded files, drafts/staged attachments, database working files and other files. It measures file metadata off the UI thread, refreshes every 30 seconds while Settings is open, and offers a manual refresh button. Symlinks are excluded; inaccessible files produce an incomplete-total notice. The figure covers this archive folder, not the app bundle, other archives or backups, and does not predict how much space a continuing import will eventually use.

Automatic local cleanup defaults **off**. When explicitly enabled and saved, it keeps a rolling 30/90/180/365/730-day window. The preview reports approximately how many saved messages are older than the selected window. The local writer removes expired message/search rows and unreferenced downloaded files; drafts and uncertain sends are retained. Cleanup never deletes from the phone. Its cutoff also bounds new imports, preventing a download/delete cycle. Turning cleanup off and choosing an earlier start can restore history still available on the phone.

Cleanup runs on connection and about daily while the app is open, after any active media batch. Message deletion and file-cleanup intents are transactional; late writes cannot recreate expired rows, and late downloaded files are queued for cleanup. Successful old outbox text/attachment references are removed while attempt IDs remain for duplicate suppression. Files shared with a retained message or draft are protected. Freed SQLite pages are reused; this is an age policy, not a guaranteed disk-size quota or secure erasure of backups.

Implementation follows Apple's [notification permission guidance](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications). Permission refreshes when the app becomes active, including after returning from Settings. On the development Mac, permission and the app toggle are now enabled. A local test was accepted and stored in Notification Center; macOS muted its banner and sound because the display was considered shared during the UI test. An unsuppressed banner and real incoming-message click routing remain device acceptance checks.

## Background receiving

Live sync runs **while Local Messages is open**. It stops when the app quits, pauses during Mac sleep, and starts a fresh connection after wake. A private process pipe and bounded shutdown deadline prevent the worker from remaining connected after its parent exits. Connection failures retry with a two-second delay increasing to one minute; an explicit Google logout or inaccessible Keychain pairing requires attention.

The worker treats live message events as requests to fetch the current conversation. A separate priority worker handles fresh events and polls recent send attempts every five seconds, even while the regular worker is listing other conversations. Per-conversation locks prevent an older fetch overwriting a newer one. A separate catch-up watermark advances only after the requested range completes; partial pages do not advance it. Recent threads refresh with a 24-hour overlap, and older events expand that refresh within the configured history window. Earlier-history backfill uses a resumable cursor and yields after each page. Google/phone response latency can still delay confirmations; phone acceptance is never labelled as recipient delivery.

Every request is served by the phone, so the worker's cadence follows whether the app is in front: it checks inbox and archive metadata on startup and every five minutes while the app is active (fifteen when idle), refreshes threads whose activity changed straight away, and sweeps recently active threads (past seven days) for receipts and reactions every thirty minutes (two hours idle). Fresh messages arrive through live events regardless. Older history is imported one page at a time with a short pause between pages (two seconds active, ten idle). This is **not an exhaustive audit of old edits made while offline**. Missing remote rows, deleted conversations, spam/blocked transitions and orphaned media still need complete reconciliation. The bounded conversation-list limitation described below also applies to live sync. Initial catch-up can take minutes on a large phone history; local browsing stays available throughout.

Contact photos are fetched after each inventory pass for people linked to a phone contact, up to 40 per pass in requests of ten, and refreshed weekly; they are saved under `media/avatars/` with user-only permissions, and a participant without a photo is remembered so the lookup is not repeated. Photo failures never stop the session. Original photos and shared contact cards run in a separate bounded batch, checked every five minutes while active (fifteen idle), up to 256 MiB of new downloads per batch in the app and 64 MiB per attachment. Each batch scans at most thirty history pages for missing download references, and an attachment whose original cannot be found or fetched backs off: an hour, then six, then a day, then weekly. The attempt count and next-attempt time are stored on the attachment, so the phone is not asked about the same old attachment every batch. Text receiving continues while those downloads run. These are fetch limits, not a total disk-storage quota. Message bodies/reactions are preserved when an older attachment download finishes. The app uses `photos-and-contacts`; other attachment types remain metadata-only.

Contact detection handles vCard MIME casing/parameters and `.vcf` filenames when the MIME type is missing or generic. Originals retain a `.vcf` extension. The preview uses Apple's [vCard parser](https://developer.apple.com/documentation/contacts/cncontactvcardserialization), without accessing the address book or fetching remote contact images. Previews are limited to 4 MiB and 100 contacts; unsupported files remain available in Finder. All six contact files in the current live archive have been downloaded and parsed successfully, containing seven contacts.

For terminal development, pause the app's sync first, then run:

```sh
./scripts/gmprobe watch --data .local-data/live --media photos-and-contacts
```

The worker emits a JSON line containing a status code, time, and an optional random connection token. It never emits message text, contacts, account identifiers or credentials. The token binds explicit send commands to the current connection so a queued command cannot unexpectedly send after reconnecting. One writer owns an archive at a time; pause app sync before running the finite importer/media command. The native reader continues to use the archive through SQLite WAL.

## Build and try the demo

Requires Apple Silicon macOS with Xcode command-line tools. The bootstrap installs Go 1.27.1 inside the ignored project cache, verifies its published SHA-256 and downloads pinned modules; it does not modify system Go installations.

```sh
./scripts/bootstrap
./scripts/build
./scripts/test
./scripts/gmprobe demo
./scripts/gmprobe search --data .local-data/demo booking
./scripts/gmprobe status --data .local-data/demo
```

The demo imports four synthetic messages in two conversations; a fifth message is intentionally older than the cutoff and excluded. Two attachments are labelled `demo_metadata_only`; no actual photo download is simulated.

## Pair with the Pixel

```sh
./scripts/gmprobe pair
```

Sign into Google in the window, then select **Continue pairing**. Confirm the emoji shown in the terminal on the Pixel. macOS may request Keychain access. Neither passwords nor cookies need to be pasted into chat or shell arguments.

The window uses an ephemeral WebKit store and only reads the Google session cookies needed for pairing after the user selects Continue. It neither reads an existing browser profile nor stores a plaintext cookie file. Google sign-in compatibility is the first live feasibility check; close the window to cancel if Google rejects the embedded browser.

Pairing uses Google's network services and registers a linked device. Sync may make this the active web session, competing with Texty or another browser. Pairing and receiving do not send messages, delete phone content or mark conversations read. Only an explicit composer action submits a text message.

The default archive is `.local-data/live`, ignored by Git. Use `--data` consistently to choose another directory. A pairing is associated with the archive's absolute path; don't move a live archive yet. Different Google accounts or phones must use separate directories.

Closing/reopening the app, pausing sync or temporarily losing the connection preserves the archive and reuses the saved pairing. If Google logs out or revokes this app's pairing, live sync stops and requests attention; saved messages, downloads and drafts remain readable offline.

To reconnect, open **Settings → Connection → Reconnect Account…**, then select **Sign In & Reconnect…**. Sign in with the original Google account, select **Continue pairing**, and confirm the displayed emoji on the original phone. The app pauses its sync worker, verifies the account and the phone's Google Messages registration, saves the verified credentials to the same Keychain entry, and resumes the previous sync setting. A different account or phone is rejected. Pairing is never started automatically just because Settings opens.

For terminal use, stop the app's sync and any terminal import first:

```sh
./scripts/gmprobe relink --data .local-data/live
```

Version 0.5 records account and phone fingerprints in the archive; cookies, keys and the pairing session remain in Keychain. Existing archives get this identity record from their original path-associated Keychain session on their next connection, or before reconnecting. If an older archive has already lost that session and has no identity record, reconnect is blocked: newly selected credentials cannot prove who owns its history. Restore access to the original Keychain entry. A phone replacement, Google Messages registration reset or account email change may require a separate archive; this flow does not migrate between identities.

Reconnect retains saved content, drafts, outbox attempts and completed history coverage. Unfinished historical pagination restarts because its opaque cursors may belong to the old session; overlapping messages retain downloaded attachments. Cancellation or a mismatch does not replace the saved credentials. If Keychain reports an uncertain save result, the app does not overwrite it with stale credentials or automatically repeat pairing; try sync, then reconnect again if necessary. Account switching is available in version 0.6; explicit sign-out and local archive deletion remain future work.

New accounts are stored under `~/Library/Application Support/local.GoogleMessagingAppMac.viewer/Archives/<UUID>`. The private `accounts.json` beside that folder stores user-chosen names and archive paths; credentials stay in separate Keychain entries. Your existing archive is registered where it already lives, preserving its Keychain association. Settings shows storage for the selected archive; inactive accounts still occupy disk space. The name in the switcher is a label you choose, not an independently verified Google email address.

Adding an already registered account/phone with a known identity is rejected before phone confirmation and credential saving; choose its existing entry and reconnect there if needed. An interrupted setup keeps a **Finish Setup** entry and its own folder for retry, including when a Keychain write result is uncertain. Switching is separate from signing out: other accounts keep their pairing and local content but do not run background sync while inactive.

## Import and inspect coverage

```sh
./scripts/gmprobe sync --since 2025-09-11 --media photos
./scripts/gmprobe status
./scripts/gmprobe search booking
./scripts/gmprobe search --conversation CONVERSATION_ID harbour
```

Omit `--since` for the same calendar date one year before today (using a midnight UTC boundary). Set it explicitly for repeatable imports. Text history and attachment metadata are fetched together; downloading files happens afterwards. The CLI default is photos, up to 1 GiB of newly downloaded data per run. `--media contacts` downloads only shared contact cards; `--media photos-and-contacts` matches the app's policy. `--media all` includes other attachments; `--media none` keeps metadata only. Before requesting missing originals, the probe refreshes their download references from current phone history. It then requests full-size metadata for any remaining originals and waits for message updates. Late updates and updates for other attachments are retained in a bounded in-memory cache. A timed-out request gets another history lookup before being marked failed. Files whose originals remain unavailable, whose declared size remains unknown, or whose declared size exceeds 64 MiB are reported instead of being silently treated as downloaded. These are adjustable prototype policies, not limits of Google Messages.

Retry photos independently of the text import:

```sh
./scripts/gmprobe media --since 2025-09-11 --media photos
```

Retry shared contacts independently with `./scripts/gmprobe media --since 2025-09-11 --media contacts` while the app's sync is paused.

Original-file resolution stops after three consecutive failures so an incompatible protocol flow does not generate an unbounded stream of requests. Text and successfully downloaded files remain available. An empty full-size-request acknowledgement alone is not counted as a downloaded original.

Attachment-reference refresh scans at most 100 pages per affected conversation and stops once the target messages are found. It updates only media metadata on already archived messages; it does not advance history checkpoints or refresh message text. An original may become available in fetched history without a new live message notification.

To continue a stopped or page-limited import:

```sh
./scripts/gmprobe sync --since 2025-09-11 --resume --media photos
```

Use the original date with `--resume`. Resume continues the earlier historical snapshot; **it does not refresh newer messages or conversations already completed**. Run without `--resume` to start from the latest page again and refresh text/reactions. Duplicate IDs update existing rows. Downloaded originals remain linked when refreshed history omits their remote download references; an explicitly changed media ID invalidates the old file reference. This finite importer is not a production sync daemon.

Status meanings:

| State | Interpretation |
|---|---|
| `boundary_reached` | That returned conversation's newest-first history crossed the requested cutoff |
| `source_exhausted` | The source returned an empty message page without a continuation cursor |
| `conversation_before_cutoff` | The conversation's latest message is already older than the requested window, so its history was skipped |
| `page_limit` | More history may exist; the per-run page budget stopped the import |
| `stalled`, `failed`, `interrupted` | Import did not complete; its last committed checkpoint remains available |
| `unordered_page`, `invalid_timestamp`, `invalid_message` | Returned data did not support a trustworthy cutoff decision |
| `downloaded_original` | Media bytes were downloaded and written locally |
| `original_unavailable` | Initial metadata lacks an original reference/key; full-size resolution has not succeeded yet |
| `downloaded_original` with `source: sent` | A file sent from this Mac, kept from its staged upload; the phone's record of an outgoing MMS often carries no download reference |
| `original_request_failed` | Requesting full-size metadata failed or produced no usable message update; a thumbnail is not substituted |

**Overall conversation inventory remains unverified.** The pinned upstream public method accepts a requested count but no conversation cursor. The probe requests inbox and archive separately, up to 1,000 each by default. It never calls that a complete inbox inventory. Spam/blocked threads are excluded. A phone comparison or a small upstream pagination enhancement is needed before claiming a complete one-year archive.

The importer preserves older locally imported rows if the cutoff is later narrowed; changing `--since` controls fetching, not retention or deletion. Deletion handling is incomplete: a returned tombstone clears its projected text, but missing remote rows and orphaned downloaded files are not reconciled. Don't treat this probe as a deletion-synchronised backup.

## Data protection and boundaries

- Pairing/session data is in this Mac's Keychain. The native helper passes secrets through pipes; Google library logging is disabled, and search output omits media decryption keys.
- The database, full-text index and downloaded media have user-only file permissions. **They are not encrypted by the application yet.** Database payloads include media download keys. Encrypted archive storage/backup is a requirement before a production release.
- No project-operated server, analytics or AI integration is included. Offline `search`, `status`, and the demo do not contact Google.
- Keychain pairing and a read-only phone connection have been manually verified on this Mac/Pixel combination. Automated tests use synthetic data and do not pair, read private messages or send to recipients.

## Licence

This prototype is AGPL-3.0, matching the core `mautrix/gmessages` dependency. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The source is published at [github.com/hasmitchell/local-messages](https://github.com/hasmitchell/local-messages); no binaries are distributed. Review the complete distribution and dependency licence obligations before a binary release.
