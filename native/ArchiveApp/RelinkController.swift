import Combine
import Foundation
import Darwin

enum RelinkState: String, Decodable, Sendable {
    case ready, stopping, signingIn = "signing_in", verifyingAccount = "verifying_account"
    case waitingForPhone = "waiting_for_phone", verifyingPairing = "verifying_pairing"
    case cancelling, cancelled, complete, wrongAccount = "wrong_account", wrongPhone = "wrong_phone"
    case accountExists = "account_exists"
    case identityMissing = "identity_missing", identityMismatch = "identity_mismatch"
    case keychainError = "keychain_error", archiveBusy = "archive_busy", timedOut = "timed_out", failed

    var terminal: Bool {
        switch self {
        case .accountExists, .cancelled, .complete, .wrongAccount, .wrongPhone, .identityMissing, .identityMismatch, .keychainError, .archiveBusy, .timedOut, .failed: true
        default: false
        }
    }
    var title: String {
        switch self {
        case .accountExists: "This account is already added"
        case .ready: "Reconnect this archive"
        case .stopping: "Pausing sync…"
        case .signingIn: "Sign in to Google"
        case .verifyingAccount: "Checking your account…"
        case .waitingForPhone: "Confirm on your phone"
        case .verifyingPairing: "Saving your verified pairing…"
        case .cancelling: "Cancelling…"
        case .cancelled: "Reconnect cancelled"
        case .complete: "Archive reconnected"
        case .wrongAccount: "A different Google account was selected"
        case .wrongPhone: "A different phone was selected"
        case .identityMissing: "Original pairing could not be verified"
        case .identityMismatch: "Archive identity does not match"
        case .keychainError: "Pairing could not be saved"
        case .archiveBusy: "This archive is still syncing"
        case .timedOut: "Pairing timed out"
        case .failed: "Reconnect did not finish"
        }
    }
    var detail: String {
        switch self {
        case .accountExists: "Choose the saved account in the switcher. If its pairing has expired, use Reconnect account in Settings. Its archive and credentials have not been changed."
        case .ready: "Sign in with the Google account and phone originally paired with this archive. Your saved messages, attachments and drafts will be kept."
        case .stopping: "Waiting for the current sync to finish shutting down."
        case .signingIn: "Complete sign-in in the Google window, then choose Continue pairing."
        case .verifyingAccount: "Checking that the account and registered phone match this archive."
        case .waitingForPhone: "Open Google Messages on your original phone and select the matching emoji."
        case .verifyingPairing: "Phone confirmation received. Keeping your archive and updating its Keychain credentials."
        case .cancelling: "Closing the pairing connection before resuming your previous sync setting."
        case .complete: "Your saved history is ready. Sync will resume if it was enabled before reconnecting."
        case .wrongAccount: "Try again with the Google account originally used for this archive. The existing pairing has not been replaced."
        case .wrongPhone: "Use the original phone and Google Messages registration. A new phone or a reset registration needs a separate archive. The existing pairing has not been replaced."
        case .identityMissing: "This older archive has no identity record and its original Keychain pairing is unavailable. Restore Keychain access and retry. A new pairing alone cannot establish which account owns the saved history."
        case .identityMismatch: "The saved pairing and this archive disagree. Restore the original Keychain pairing or use a separate archive."
        case .keychainError: "Check macOS Keychain access, then try syncing. The save result is uncertain; if sync still needs pairing, reconnect again."
        case .archiveBusy: "Stop any terminal import or other app using this archive, then try again."
        case .timedOut: "Have your original phone ready and try again. Your saved archive is still available."
        case .cancelled: "Your saved archive is still available. You can reconnect again whenever you are ready."
        case .failed: "Check your connection, Google sign-in and Keychain access, then try again. Your saved archive is still available."
        }
    }
}

struct RelinkStatus: Decodable, Sendable {
    let state: RelinkState
    let emoji: String?

    static func parse(_ line: String) -> RelinkStatus? {
        guard line.utf8.count < 512, let data = line.data(using: .utf8),
              let status = try? JSONDecoder().decode(Self.self, from: data),
              status.emoji == nil || (status.state == .waitingForPhone && status.emoji!.utf8.count <= 64 && status.emoji!.count <= 4 && !status.emoji!.isEmpty) else { return nil }
        // The worker cannot drive UI-only transitions.
        guard ![.ready, .stopping, .cancelling].contains(status.state) else { return nil }
        return status
    }
}

@MainActor
final class RelinkController: ObservableObject {
    @Published private(set) var state: RelinkState = .ready
    @Published private(set) var emoji: String?
    @Published private(set) var busy = false
    private let workerURL: URL
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var preparation: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var finished: (() -> Void)?
    private var cancelled = false
    private var lastStatus: RelinkState?

    init(workerURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gmprobe")) {
        self.workerURL = workerURL
    }

    func reset() { guard !busy else { return }; state = .ready; emoji = nil }

    func start(directory: URL, addingAccount: Bool = false, existingArchives: [URL] = [], prepare: @escaping () async throws -> Void, finished: @escaping () -> Void) {
        guard !busy else { return }
        busy = true; state = .stopping; emoji = nil; cancelled = false; lastStatus = nil
        self.finished = finished
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepare()
                try Task.checkCancellation()
                self.launch(directory, addingAccount: addingAccount, existingArchives: existingArchives)
            } catch {
                self.finish(self.cancelled ? .cancelled : .archiveBusy)
            }
        }
    }

    private func launch(_ directory: URL, addingAccount: Bool, existingArchives: [URL]) {
        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else { finish(.failed); return }
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = workerURL
        child.arguments = [addingAccount ? "pair" : "relink", "--data", directory.path, "--status-json", "--parent-stdin"]
        if addingAccount { child.arguments! += existingArchives.flatMap { ["--existing-archive", $0.path] } }
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            let code = child.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                // Drain the final status before interpreting process exit.
                await self.reader?.value
                let result: RelinkState
                if code == 0 && self.lastStatus == .complete { result = .complete }
                else if self.cancelled { result = .cancelled }
                else if let status = self.lastStatus, status.terminal && status != .complete { result = status }
                else { result = .failed }
                self.finish(result)
            }
        }
        do {
            try child.run()
            self.process = child; self.input = input; self.output = output
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            reader = Task { [weak self] in
                do {
                    for try await line in output.fileHandleForReading.bytes.lines {
                        guard let self, !Task.isCancelled else { return }
                        guard let status = RelinkStatus.parse(line), self.lastStatus?.terminal != true else { continue }
                        self.lastStatus = status.state
                        if !self.cancelled { self.state = status.state; self.emoji = status.emoji }
                    }
                } catch { /* The final exit status handles interrupted pipes. */ }
            }
        } catch { finish(.failed) }
    }

    func cancel() {
        guard busy, !cancelled else { return }
        cancelled = true; state = .cancelling; emoji = nil
        preparation?.cancel()
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
            Task {
                try? await Task.sleep(for: .seconds(6))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finish(_ result: RelinkState) {
        try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close()
        input = nil; output = nil; process = nil; reader = nil; preparation = nil
        emoji = nil; state = result; busy = false
        let callback = finished; finished = nil
        callback?()
    }
}
