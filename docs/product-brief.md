# Product brief

Confirmed with the user on 11 September 2026.

- Primary phone: Pixel 10 Pro using Google Messages. Android version is not yet known.
- Desktop: 14-inch M5 MacBook Pro; the development machine reports Apple Silicon, macOS 26.6.2 and Xcode 26.5.
- More than ten years of history exist. Prioritise the most recent calendar year of messages and photos. Older history is optional, not a prerequisite for usefulness.
- Required for replacing Texty: sending and receiving SMS and RCS, attachments, reactions, and desktop notifications.
- RCS typing indicators are desirable. RCS group messaging is a lower priority.
- macOS first. An iOS companion is a later feasibility decision.
- Storage and processing stay local; no required project-operated backend.

## First milestone

A read-only connectivity and archive probe, before building a replacement chat UI. Validate account pairing, history coverage, original media availability, local persistence and search. The probe must distinguish an archive boundary from a request limit or protocol failure.

The probe does not meet the replacement-app feature requirements yet. Sending, upload, reactions, notifications and continuous synchronisation are subsequent milestones after testing with the Pixel.

## Native archive viewer milestone

A SwiftUI Mac app now uses the imported archive for conversation browsing, paged history, global/scoped local search, result-to-message navigation and native attachment previews. It displays saved reactions and reply references. This milestone makes phone/archive comparisons practical without adding sending or a continuously running sync service.

## Acceptance checks with the phone

1. Pair using a Google account and the phone's emoji confirmation.
2. Compare several recent SMS and RCS conversations with the phone, including a busy thread spanning more than a year and an archived thread.
3. Match dates, text, incoming/outgoing direction, replies, reactions and multi-attachment messages.
4. Open several downloaded originals, not just thumbnail previews.
5. Search downloaded content with the Mac offline and the phone unavailable.
6. Interrupt and resume an import; confirm no duplicated messages or lost progress.
7. Test a competing web session, sleep/wake and expired account credentials.
8. Only then implement and manually verify sending, uploads, reactions and notifications. No automated test sends to real recipients.


### Background receiving prototype

The Mac app now starts and stops a local receive worker, displays connection state, supports pause/resume/reconnect, and refreshes saved conversations/search automatically. An older message remains in view when updates arrive; a latest-messages action navigates to new arrivals. Original photos download in background batches. Composer/send flow and desktop notifications remain the next product milestones; sleep/wake handling and upstream reconnection need extended real-device testing before a release.


### Text replies and notifications prototype

Existing conversations now have a multiline text composer, persistent drafts and an outbox that distinguishes phone acceptance from delivery and uncertain sends. Reconnecting never automatically repeats a send attempt. Desktop notifications have permission controls, optional previews, historical-import suppression and conversation navigation. Actual recipient delivery from the composer and notifications with granted macOS permission still need live validation. New conversations, attachment uploads and sending reactions remain outstanding.

### User review and version 0.4 (11 September 2026)

The user verified an SMS sent from the composer and received a reply. Requested refinements: faster phone-send confirmation, automatic display of replies at the latest edge, dependable notification behavior, separate conversation/global search, phone numbers, thread photos/links, appearance/history/optional retention settings, and attachment/reaction actions.

These features are implemented in 0.4. Live events and recent sends have a priority refresh path; timeline following depends on scroll position, and notification suppression depends on actual foreground visibility. Each conversation has its own expandable search and details library. Settings offers system/light/dark appearance, custom/longer history and optional local cleanup, defaulting off. The composer stages files locally and sends only on explicit Send; message menus support adding/replacing/removing a reaction. No automated test sends to real recipients. Device acceptance still needs RCS delivery, attachment/reaction submission, notification-click routing, and send-status timing under normal use. New-conversation creation and typing indicators remain later work.

### Follow-up review and version 0.4.1 (11 September 2026)

The user confirmed reactions work and sending now feels substantially faster. They also verified appearance/history settings and chose five years of history with cleanup off. This pass focuses the thread search on opening, attaches reaction badges to the bubble edge, removes reaction actions from outgoing messages, and adds conversation-list back-to-top and thread jump-to-latest shortcuts. Synthetic UI checks cover both shortcuts, automatic arrivals and preservation of an older reading position.

The user reported a local image failing during attachment preparation. Staging now reads the opened file's actual metadata, loops through partial reads, compares canonical storage paths and gives specific read/storage/name errors. Native checks cover stale picker metadata and oversized images. The exact reported image has not yet been supplied for reproduction; real image submission remains an acceptance check.

### Archive storage visibility — version 0.4.2 (11 September 2026)

Settings shows the current archive's approximate disk usage, available drive space and a breakdown by database, downloaded media, drafts, working files and other files. Measurement runs off the UI thread and refreshes while Settings is open, so people can assess local retention without leaving the app. It does not change retention or download settings.

### Verified archive reconnect — version 0.5.0 (11 September 2026)

Settings now offers an explicit reconnect flow for expired/revoked pairings. It pauses sync, signs into Google, checks the original account and registered phone, shows the phone-confirmation emoji, then updates the same Keychain entry and resumes the prior sync setting. Different identities cannot attach to the archive. Fingerprints are bound on initial pairing and migrated from the original Keychain entry for older archives; an older archive without either identity metadata or its original credentials cannot be relinked safely.

The archive, media, drafts, outbox attempts and completed history coverage survive. Unfinished opaque cursors restart. Automated checks use synthetic identities and workers to cover matching/mismatched identities, cancellation, Keychain failure, worker ownership and preservation of local content. Actual Google re-pairing remains a manual sign-in/phone-confirmation check. Sign-out, moved archive recovery and local deletion are separate future work.

### Account switcher — version 0.6.0 (11 September 2026)

The sidebar account menu switches among named account archives. Add Account performs native Google sign-in and phone confirmation into a new directory, with an independent Keychain entry. Manage Accounts supports renaming and resuming interrupted setup. The existing archive is registered in place as Personal; no files or credentials are moved. Completed account/phone identities prevent duplicate setup. Unknown or reset phone identities still cannot attach to an existing archive.

Switching clears visible conversation/search/media state and notification routing, stops the previous worker, loads the selected archive's drafts and settings, then starts one worker if sync is enabled. Normal launches restore the last selection. Inactive accounts remain saved and consume storage but do not sync or notify. Each newly created archive defaults to one year of history and cleanup off; notification/appearance preferences and the sync pause preference are app-wide.

Automated checks cover catalog persistence and migration, duplicate pairing, cancelled setup, wrong identities, distinct drafts/settings with shared conversation IDs, and non-overlapping worker lifetimes. Synthetic UI checks exercise account creation and switching. Real pairing of another account remains a user sign-in and phone-confirmation acceptance check; no automated check logs into Google or sends a message.

### Interface overhaul — version 0.7.0 (11 September 2026)

The user asked for a full review and for the app to look and behave less like a prototype. The window now uses a native sidebar search field, a segmented Inbox/Archived filter, an account menu in the sidebar toolbar and a compact status bar. Conversation rows show relative dates, unread markers (phone unread state combined with a local "seen" watermark, also shown on the Dock icon) and unsent drafts. The timeline groups consecutive messages, labels time gaps, reveals per-message time/transport/delivery on hover, shows delivery status under the latest outgoing message, quotes replies compactly, makes web links clickable and sizes photos by their real aspect ratio. Conversation details moved from a sheet to a trailing inspector (⌘I) that persists across conversations, and Settings moved from a sheet to a tabbed Settings window (General, Notifications, Connection, History & Storage). The composer is a single rounded field that grows with the draft and only shows a note when something needs attention.

Bugs fixed during the review: reply quotes stretched bubbles to the maximum width, the composer height counted newlines instead of wrapped lines, notification suppression treated any key window (including Settings) as the conversation being visible, empty conversation names showed "Unnamed conversation" instead of the participant, and thread search did not run if a query was set before its field mounted. A synthetic snapshot harness (`./scripts/snapshot-app`) renders the interface to PNG on the fixture without screen-recording permission; the build script now stages the bundle and swaps it in so a running copy is not overwritten. Native checks pass; the user's live archive and the running app were not modified. Real-device checks of the hover reactions, unread markers and the inspector against the paired phone remain acceptance work.

### Contact photos, details popover and toolbar find — version 0.7.1 (11 September 2026)

On a 14-inch screen the details inspector did not fit beside the sidebar and timeline, so contact details now open as a popover from the contact's photo in the toolbar (also ⌘I). The in-conversation find field moved into the toolbar, where macOS 26 collapses it to its icon until used, with matches listed in a panel beneath it. The worker now fetches the phone's contact photos through the protocol library's participant-thumbnail request and stores them in the archive; the app shows them in the sidebar, search results, toolbar and details. A number-only conversation no longer repeats the number as its subtitle.

### New conversations — version 0.7.2 (11 September 2026)

The user asked to text a number that has no conversation yet. New Message (⌘N or the sidebar pencil button) takes a phone number; the worker sends a durable `start` command through the existing outbox path, asks the phone for the conversation belonging to that number (the phone returns an existing thread when there is one), stores it and reports the result, and the app opens the thread for composing. Failures distinguish a lost connection from a number the phone rejected, and an unanswered request times out after a minute. Group creation remains out of scope. The synthetic tests cover the resolved, rejected, offline and unsupported paths and duplicate suppression; sending to a genuinely new number is a live acceptance check.

### Read status and spelling — version 0.7.3 (11 September 2026)

Viewing a conversation's newest messages on the Mac now sends the phone a read marker for the latest message, so the phone stops showing it unread; the request is best effort, needs no outbox row, and updates the local unread flag immediately when the phone accepts it. General settings can turn it off, restoring the earlier behaviour where reading here was invisible to the phone. The composer's text view now checks spelling continuously, with automatic correction as an opt-in. Synthetic tests cover the read marker's success, failure, stale-connection and unsupported paths; the phone-side effect is a live check.
