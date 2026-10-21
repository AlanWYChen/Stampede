import AppKit
import Combine
import ServiceManagement

#if canImport(StampedeCore)
    import StampedeCore
#endif

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var history: History
    @Published private(set) var currentID: UUID?
    @Published private(set) var storageStatus = "Loading saved history…"
    @Published private(set) var accessRequired = false
    @Published private(set) var accessState: ClipboardAccessState = .unknown
    @Published private(set) var accessFeedback: String?
    @Published private(set) var ready = false
    @Published private(set) var loginStatus = ""
    @Published private(set) var operationError: String?
    @Published private(set) var setupComplete: Bool
    @Published private(set) var paused: Bool
    var onRecoveryNeeded: ((String) -> Void)?
    private let defaults: UserDefaults
    private let clipboard: SystemClipboardClient
    private let monitor: ClipboardMonitor
    private let repository: HistoryRepository
    private var generation: UInt64 = 0
    private var saveTask: Task<Void, Never>?
    private var loading = false
    private var timer: Timer?
    private var loadedOnce = false
    private let imageProcessor = ImageProcessor()
    private var captures = CaptureCoordinator()
    private var imageTasks: [UUID: Task<Void, Never>] = [:]
    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        defaults = .standard
        let capacity = defaults.integer(forKey: "historyCapacity")
        history = History(capacity: capacity == 10 ? 10 : 20)
        setupComplete = defaults.bool(forKey: "setupComplete")
        paused = defaults.bool(forKey: "capturePaused")
        // Earlier builds had no explicit marker. An already configured install expects saved history.
        if !preview, defaults.bool(forKey: "setupComplete"), defaults.object(forKey: "hasSavedHistory") == nil {
            defaults.set(true, forKey: "hasSavedHistory")
        }
        clipboard = SystemClipboardClient()
        monitor = ClipboardMonitor(clipboard: clipboard)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The stable storage directory preserves history from existing installations.
        repository = HistoryRepository(
            fileURL: support.appendingPathComponent("com.alanwychen.rotarystamp/history.enc")
        )
        monitor.onCapture = { [weak self] text in
            guard let self else { return }
            self.operationError = nil
            self.currentID = self.history.capture(text, now: self.captures.observe())
            self.scheduleSave()
        }
        monitor.onImage = { [weak self] candidate, revision in self?.captureImage(candidate, revision: revision) }
        monitor.onImageRejected = { [weak self] message in self?.operationError = message }
        monitor.onInactive = { [weak self] in self?.currentID = nil }
        monitor.onAccessRequired = { [weak self] in self?.accessRequired = true }
        if preview {
            setupComplete = true
            history = History(entries: [
                ClipboardEntry(text: "Welcome to Stampede"), ClipboardEntry(text: "A previous clipboard item"),
                ClipboardEntry(text: "https://developer.apple.com"),
            ])
            if let bytes = ClipboardSelfTest.sampleImageData(),
                let image = try? ImageProcessor.prepare(
                    ImageCandidate(type: "public.png", data: bytes, sourceApp: "Safari", sourceHost: "example.com")
                )
            {
                history.capture(ClipboardEntry(image: image))
            }
            ready = true
            storageStatus = "Preview — no clipboard or storage access"
            loginStatus = "Preview — login registration disabled"
            return
        }
        refreshLoginStatus()
        refreshClipboardAccess()
        if setupComplete { load() } else { storageStatus = "Enable history to get started" }
    }

    private func captureImage(_ candidate: ImageCandidate, revision: Int) {
        guard let ticket = captures.reserve(bytes: candidate.data.count) else {
            operationError = "Image processing is busy. Copy the image again after it finishes."
            return
        }
        let taskID = UUID()
        imageTasks[taskID] = Task {
            defer {
                captures.finish(ticket)
                imageTasks.removeValue(forKey: taskID)
            }
            do {
                let image = try await imageProcessor.process(candidate)
                guard captures.accepts(ticket, capacity: history.capacity), !paused else { return }
                let id = history.capture(ClipboardEntry(image: image, capturedAt: ticket.time, lastUsedAt: ticket.time))
                if clipboard.revision == revision { currentID = id }
                operationError = nil
                scheduleSave()
            } catch {
                guard captures.accepts(ticket, capacity: history.capacity), clipboard.revision == revision else {
                    return
                }
                operationError = error.localizedDescription
            }
        }
    }

    func completeSetup() {
        guard !preview else { return }
        setupComplete = true
        defaults.set(true, forKey: "setupComplete")
        // Only first setup registers automatically. Later launches respect the system's choice.
        setLoginEnabled(true)
        load(userInitiated: true)
    }

    func load(userInitiated: Bool = false) {
        guard setupComplete, !preview, !loading, !loadedOnce else { return }
        loading = true
        storageStatus = "Loading saved history…"
        Task {
            do {
                let entries = try await repository.load(
                    requireExisting: defaults.bool(forKey: "hasSavedHistory"),
                    userInitiated: userInitiated
                )
                history = History(entries: entries, capacity: history.capacity)
                _ = captures.observe(now: entries.map(\.lastUsedAt).max() ?? Date())
                ready = true
                loadedOnce = true
                loading = false
                storageStatus = "History saved locally · encrypted"
                if !paused {
                    monitor.poll(userInitiated: userInitiated)
                    refreshClipboardAccess()
                } else {
                    monitor.baseline()
                }
                // Persist capacity trimming, including a setting changed before this launch.
                scheduleSave()
                startTimer()
            } catch {
                loading = false
                storageStatus = "History unavailable: \(error.localizedDescription)"
                onRecoveryNeeded?(error.localizedDescription)
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func poll() {
        guard ready, !preview else { return }
        refreshClipboardAccess()
        if paused {
            // Watching revisions does not read content, and keeps the checkmark honest while paused.
            if monitor.processedRevision != clipboard.revision { monitor.baseline() }
        } else {
            monitor.poll()
        }
    }

    func refreshClipboardAccess() {
        guard !preview else { return }
        accessState = clipboard.accessState
        accessRequired = accessState != .allowed
    }

    func requestAccess() {
        guard !preview else {
            accessFeedback = "Preview mode does not read your clipboard."
            return
        }
        guard ready else {
            accessFeedback = "Enable clipboard history and load saved history before checking access."
            return
        }
        refreshClipboardAccess()
        if accessState.needsPermissionProbe {
            // A separate read, not a capture tick: unchanged text and paused history are both safe.
            monitor.probeAccess()
            refreshClipboardAccess()
        }
        let time = Date().formatted(date: .omitted, time: .standard)
        switch accessState {
        case .allowed:
            accessFeedback =
                "Checked at \(time). Access is already allowed; no permission dialog is needed. "
                + (paused
                    ? "Capture is paused. Turn on Capture new copies to resume."
                    : "New text and image copies can be added to your history.")
        case .notDetermined:
            accessFeedback =
                "Checked at \(time). macOS has not recorded a permission choice yet. Copy some text in another app, then check again. A dialog appears only when macOS requires one."
        case .ask:
            accessFeedback =
                "Checked at \(time). macOS is set to ask for access. Choose Always Allow for Stampede in its clipboard privacy settings to enable continuous capture."
        case .denied:
            accessFeedback =
                "Checked at \(time). macOS is blocking clipboard reads. Open System Settings and change Stampede’s clipboard access to Allow or Always Allow."
        case .unknown:
            accessFeedback =
                "Checked at \(time). Clipboard access could not be determined. Review Stampede’s clipboard permission in System Settings."
        }
    }

    func openSystemSettings() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences"),
            NSWorkspace.shared.open(url)
        else {
            accessFeedback =
                "System Settings could not be opened. Open it from the Apple menu and search for clipboard or paste permissions."
            return
        }
    }

    func activate(_ id: UUID) {
        guard ready, let entry = history.entries.first(where: { $0.id == id }) else {
            operationError = "This entry is no longer in history. Reopen the menu."
            return
        }
        guard !preview else {
            promote(entry)
            return
        }
        if !paused { monitor.poll() }
        guard entry.image?.data != nil || entry.image == nil else {
            operationError = "This saved image is missing or unreadable. Other entries are still available."
            return
        }
        guard entry.image.map({ monitor.activateImage($0) }) ?? monitor.activate(entry.text) else {
            operationError = "The clipboard could not be updated and may now be empty. Please try again."
            return
        }
        operationError = nil
        promote(entry)
        scheduleSave()
    }

    private func promote(_ entry: ClipboardEntry) {
        let now = captures.observe()
        currentID = history.capture(
            entry.image.map { ClipboardEntry(image: $0, capturedAt: entry.capturedAt, lastUsedAt: now) }
                ?? ClipboardEntry(text: entry.text, capturedAt: entry.capturedAt, lastUsedAt: now)
        )
    }

    func setCapacity(_ value: Int) {
        guard ready else { return }
        captures.invalidate()
        history.setCapacity(value)
        if !history.entries.contains(where: { $0.id == currentID }) { currentID = nil }
        if !preview {
            defaults.set(history.capacity, forKey: "historyCapacity")
            scheduleSave()
        }
    }

    func togglePause() {
        captures.invalidate()
        paused.toggle()
        if !preview {
            defaults.set(paused, forKey: "capturePaused")
            monitor.baseline()
        }
    }

    func clearClipboard() {
        guard ready else { return }
        captures.invalidate()
        history.clear()
        currentID = nil
        operationError = nil
        if !preview {
            monitor.clearClipboard()
            scheduleSave(immediate: true)
        }
    }

    func resetHistory() {
        guard setupComplete, !preview, !loading else { return }
        captures.invalidate()
        saveTask?.cancel()
        generation += 1
        let revision = generation
        ready = false
        loading = true
        timer?.invalidate()
        timer = nil
        storageStatus = "Resetting saved history…"
        Task {
            do {
                try await repository.reset(generation: revision)
                history.clear()
                currentID = nil
                monitor.baseline()
                defaults.set(true, forKey: "hasSavedHistory")
                ready = true
                loadedOnce = true
                loading = false
                operationError = nil
                storageStatus = "History saved locally · encrypted"
                startTimer()
            } catch {
                loading = false
                storageStatus = "History could not be reset: \(error.localizedDescription)"
                onRecoveryNeeded?(error.localizedDescription)
            }
        }
    }

    func retry() {
        guard setupComplete else { return }
        operationError = nil
        if !loadedOnce {
            load(userInitiated: true)
        } else if ready {
            scheduleSave(immediate: true, userInitiated: true)
        } else {
            loadedOnce = false
            load(userInitiated: true)
        }
    }

    private func scheduleSave(immediate: Bool = false, userInitiated: Bool = false) {
        guard ready, !preview else { return }
        generation += 1
        let revision = generation
        let entries = history.entries
        storageStatus = "Saving history…"
        saveTask?.cancel()
        saveTask = Task {
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            for attempt in 0..<4 {
                guard !Task.isCancelled, generation == revision else { return }
                do {
                    try await repository.save(
                        entries,
                        generation: revision,
                        userInitiated: userInitiated && attempt == 0
                    )
                    if generation == revision {
                        defaults.set(true, forKey: "hasSavedHistory")
                        storageStatus = "History saved locally · encrypted"
                    }
                    return
                } catch {
                    guard generation == revision else { return }
                    storageStatus = "History changes are not saved: \(error.localizedDescription)"
                    if attempt == 3, error is HistoryStorageError { onRecoveryNeeded?(error.localizedDescription) }
                    if attempt < 3 {
                        do { try await Task.sleep(for: .seconds(1 << attempt)) } catch { return }
                    }
                }
            }
        }
    }

    func prepareToQuit() async -> Bool {
        timer?.invalidate()
        timer = nil
        guard ready, !preview else { return true }
        // Finish copies already observed before the final snapshot is taken.
        for task in Array(imageTasks.values) { await task.value }
        saveTask?.cancel()
        generation += 1
        do {
            try await repository.save(history.entries, generation: generation)
            defaults.set(true, forKey: "hasSavedHistory")
            return true
        } catch {
            storageStatus = "History changes are not saved: \(error.localizedDescription)"
            startTimer()
            return false
        }
    }

    func refreshLoginStatus() {
        guard !preview else { return }
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "Enabled — Stampede opens when you sign in"
        case .requiresApproval: loginStatus = "Approval needed in System Settings → Login Items"
        case .notRegistered: loginStatus = "Disabled"
        case .notFound: loginStatus = "Unavailable — install Stampede.app, then retry"
        @unknown default: loginStatus = "Unknown login-item status"
        }
    }

    var loginEnabled: Bool { !preview && SMAppService.mainApp.status == .enabled }

    func setLoginEnabled(_ enabled: Bool) {
        guard !preview else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            loginStatus += " · Could not update registration: \(error.localizedDescription)"
        }
    }
}
