import Observation

// Keystrokes invalidate only views that read the draft text (the composer).
// Sidebar previews are published by ArchiveModel after a brief pause,
// alongside the batched disk save.
@MainActor @Observable
final class ComposerDraftState {
    var records: [String: DraftRecord] = [:]
}
