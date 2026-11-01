import AVFoundation
import Observation
import SwiftUI
import XCTest
import SwiftData
@testable import Woadie

final class EngineSupervisorTests: XCTestCase {
    @available(macOS 26.0, *)
    func testGlassSurfacesAlwaysUseActiveMaterialAppearance() {
        XCTAssertEqual(GlassActivityPolicy.materialAppearance, .active)
    }

    func testWindowChromeIsNotReappliedDuringActivationChanges() {
        XCTAssertFalse(WindowChromePolicy.reappliesDuringActivationChanges)
    }

    func testAppearanceDefaultsToSystemAndPersistsSelection() {
        let suiteName = "AppearanceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppAppearance.load(from: defaults), .system)

        AppAppearance.dark.save(to: defaults)

        XCTAssertEqual(AppAppearance.load(from: defaults), .dark)
    }

    @MainActor
    func testSpeechEntryArchiveRoundTripCopiesAudioAndPreservesMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceDirectory = support.appendingPathComponent("Woadie/Clips/source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceAudio = sourceDirectory.appendingPathComponent("clip.wav")
        try Data("audio".utf8).write(to: sourceAudio)

        let entry = SpeechEntry(
            textContent: "Archive me",
            voice: "af_heart",
            segmentRelativePaths: ["Woadie/Clips/source/clip.wav"],
            segmentDurations: [1.25],
            totalDurationSeconds: 1.25,
            stats: QueryStats(
                tokenCount: 2,
                generationTimeSeconds: 0.5,
                fileSizeBytes: 5,
                characterCount: 10,
                segmentCount: 1,
                resourceBefore: .empty,
                resourceAfter: .empty
            )
        )
        let service = SpeechEntryArchiveService(fileManager: .default, applicationSupportDirectory: support)

        let exported = try service.export(entry: entry, to: exports)
        let imported = try service.importEntry(from: exported)

        XCTAssertEqual(imported.textContent, entry.textContent)
        XCTAssertEqual(imported.voice, entry.voice)
        XCTAssertEqual(imported.segmentDurations, [1.25])
        XCTAssertEqual(imported.stats.characterCount, 10)
        XCTAssertEqual(imported.segmentRelativePaths.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(imported.segmentRelativePaths[0]).path))
    }

    @MainActor
    func testSpeechEntryArchiveRejectsMissingSegmentBeforeImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let archive = root.appendingPathComponent("SpeechExport_Test", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = SpeechEntryArchiveManifest(
            id: UUID(),
            createdAt: Date(),
            textContent: "Missing",
            voice: "af_heart",
            model: "Kokoro",
            audioPaths: ["segment_000.wav"],
            segmentDurations: [1],
            totalDurationSeconds: 1,
            stats: .empty,
            appMode: .pro
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: archive.appendingPathComponent("manifest.json"))
        let service = SpeechEntryArchiveService(fileManager: .default, applicationSupportDirectory: support)

        XCTAssertThrowsError(try service.importEntry(from: archive)) {
            XCTAssertEqual(($0 as? SpeechEntryArchiveError), .missingAudioFile("segment_000.wav"))
        }
    }

    func testEngineErrorDescriptionsAreHumanReadable() {
        XCTAssertEqual(EngineError.exitCode(9).errorDescription, "Kokoro exited unexpectedly with code 9.")
        XCTAssertEqual(EngineError.portConflict.errorDescription, "Port 7777 is already in use by another process.")
        XCTAssertEqual(EngineError.venvMissing.errorDescription, "The Kokoro Python virtual environment is missing.")
    }

    func testEngineStateProvidesDescriptiveStatusText() {
        XCTAssertEqual(EngineState.starting.statusText, "Starting Engine…")
        XCTAssertEqual(EngineState.ready.statusText, "Engine Ready")
        XCTAssertEqual(EngineState.degraded(reason: "health check timed out").statusText, "Degraded — health check timed out")
        XCTAssertEqual(EngineState.unreachable.statusText, "Cannot reach localhost:7777")
        XCTAssertEqual(
            EngineState.stopped(error: .exitCode(2)).statusText,
            "Engine Stopped — Kokoro exited unexpectedly with code 2."
        )
    }

    func testTTSRequestTimeoutIsThreeMinutes() {
        XCTAssertEqual(AppConfig.requestTimeoutSeconds, 180)
    }

    func testSentenceBatcherKeepsShortInputWhole() {
        XCTAssertEqual(TextBatcher.segments(for: "Short text."), ["Short text."])
    }

    func testSentenceBatcherSplitsAtSentenceBoundaryAfterTarget() {
        let first = String(repeating: "A", count: 205) + "."
        let second = String(repeating: "B", count: 80) + "."

        XCTAssertEqual(TextBatcher.segments(for: "\(first) \(second)"), [first, second])
    }

    func testSentenceBatcherDoesNotSplitDecimalsAbbreviationsOrEllipsis() {
        let prefix = String(repeating: "A", count: 195)
        let text = "\(prefix) Dr. Smith measured 3.14 units... Then the final sentence ends here. Next sentence."
        let segments = TextBatcher.segments(for: text)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].contains("Dr. Smith"))
        XCTAssertTrue(segments[0].contains("3.14 units..."))
        XCTAssertTrue(segments[0].hasSuffix("here."))
    }

    func testSentenceBatcherHardCutsUnbrokenTextIntoEvenPieces() {
        let text = String(repeating: "x", count: 620)
        let segments = TextBatcher.segments(for: text)

        XCTAssertEqual(segments.map(\.count), [206, 207, 207])
        XCTAssertEqual(segments.joined(), text)
    }

    func testRequestPolicyNeverCreatesSegmentOver250Characters() {
        let segments = EngineRequestPolicy.live.segments(for: String(repeating: "Long text without punctuation ", count: 40))

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 250 })
    }

    func testTTSQueueProcessesStrictlySequentiallyAndPublishesReadyURLs() async {
        let queue = TTSQueue()
        await queue.enqueue(["One.", "Two.", "Three."])
        let recorder = QueueRecorder()

        await queue.process(
            generate: { segment in
                await recorder.started(segment.index)
                try? await Task.sleep(nanoseconds: 10_000_000)
                await recorder.finished(segment.index)
                return GeneratedSegment(
                    audioURL: URL(fileURLWithPath: "/tmp/\(segment.index).wav"),
                    durationSeconds: nil
                )
            },
            onReady: { segment in
                await recorder.ready(segment.index)
            }
        )

        let events = await recorder.events
        XCTAssertEqual(
            events,
            ["start-0", "finish-0", "ready-0", "start-1", "finish-1", "ready-1", "start-2", "finish-2", "ready-2"]
        )
        let snapshot = await queue.snapshot()
        let isProcessing = await queue.processing
        XCTAssertFalse(isProcessing)
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertTrue(snapshot.allSatisfy {
            if case .ready = $0.status { return true }
            return false
        })
    }

    func testPlaybackTimelineUsesActualDurationsForBufferedSegmentsAndEstimatesTheRest() {
        var timeline = PlaybackTimeline(segmentCharacterCounts: [150, 300, 150])
        timeline.markReady(index: 0, duration: 1.2)
        timeline.markReady(index: 1, duration: 2.4)

        XCTAssertEqual(timeline.bufferedDuration, 3.6, accuracy: 0.001)
        XCTAssertEqual(timeline.totalDuration, 4.6, accuracy: 0.001)
    }

    func testPlaybackTimelineResolvesGlobalTimeToSegmentLocalTime() {
        var timeline = PlaybackTimeline(segmentCharacterCounts: [150, 150, 150])
        timeline.markReady(index: 0, duration: 1.25)
        timeline.markReady(index: 1, duration: 2.0)

        let target = timeline.location(for: 2.75)
        XCTAssertEqual(target?.segmentIndex, 1)
        XCTAssertEqual(target?.localTime ?? -1, 1.5, accuracy: 0.001)
    }

    func testPlaybackTimelineRejectsUnbufferedSeek() {
        var timeline = PlaybackTimeline(segmentCharacterCounts: [150, 150])
        timeline.markReady(index: 0, duration: 1)

        XCTAssertNil(timeline.location(for: 1.01))
        XCTAssertNotNil(timeline.location(for: 1.0))
    }

    func testVoiceCyclingWrapsInBothDirections() {
        let voices = ["a", "b", "c"]

        XCTAssertEqual(VoiceCycler.next(current: "c", in: voices, offset: 1), "a")
        XCTAssertEqual(VoiceCycler.next(current: "a", in: voices, offset: -1), "c")
    }

    @MainActor
    func testSpeakCanRetryAfterPlaybackFailure() {
        let store = AppStore()
        store.composerText = "Try again"
        store.engineStatus = .running
        store.playback.state = .failed
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))

        XCTAssertTrue(model.canSpeak)
    }

    @MainActor
    func testPlaybackTickNotifiesOnlyReadersOfChangedFields() {
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        var elapsedChanged = false
        var playingIdChanged = false
        withObservationTracking { _ = model.playback.elapsedTime } onChange: { elapsedChanged = true }
        withObservationTracking { _ = model.playingId } onChange: { playingIdChanged = true }

        store.playback.elapsedTime = 1.5

        XCTAssertTrue(elapsedChanged)
        XCTAssertFalse(playingIdChanged, "A time tick must not re-render views that only show the playing entry")
    }

    @MainActor
    func testPlaybackPanelRedrawsOnPlaybackTick() {
        let store = AppStore()
        store.playback.duration = 120
        store.playback.bufferedDuration = 120
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        let host = NSHostingView(rootView: WoadiePlaybackPanel(model: model, onTogglePlayback: {}).frame(width: 330, height: 320))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        func render() -> Data {
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.tiffRepresentation!
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let before = render()

        store.playback.elapsedTime = 65
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let after = render()

        XCTAssertNotEqual(before, after, "The elapsed time and scrubber must redraw when playback ticks")
    }

    // MARK: Audiobook mode (X6)

    func testChapterSplitterFindsHeadingsAndChapterLines() {
        let markdown = "Some opening words that are short.\n# The Harbor\nBoats and gulls.\n# The Storm\nWind and rain."
        let chapters = ChapterSplitter.chapters(in: markdown, fallbackTitle: "Book")
        XCTAssertEqual(chapters.map(\.title), ["The Harbor", "The Storm"])
        XCTAssertTrue(chapters[0].text.contains("Some opening words"), "A short opening joins the first chapter")
        XCTAssertTrue(chapters[0].text.hasPrefix("The Harbor."), "Each chapter starts by reading its title")

        let novel = "CHAPTER I\nIt began.\nChapter II: The Storm\nIt rained.\nChapter Three\nIt ended."
        XCTAssertEqual(ChapterSplitter.chapters(in: novel, fallbackTitle: "Book").map(\.title), ["CHAPTER I", "Chapter II: The Storm", "Chapter Three"])

        let plain = "Just one long piece of text with no chapters at all."
        XCTAssertEqual(ChapterSplitter.chapters(in: plain, fallbackTitle: "Notes").map(\.title), ["Notes"])
    }

    func testBookIDIsStableForTheSameDocument() {
        let chapters = [BookChapter(title: "One", text: "A"), BookChapter(title: "Two", text: "B")]
        XCTAssertEqual(Book(title: "T", source: "t.epub", chapters: chapters).id, Book(title: "T", source: "t.epub", chapters: chapters).id)
        XCTAssertNotEqual(Book(title: "T", source: "t.epub", chapters: chapters).id, Book(title: "T", source: "u.epub", chapters: chapters).id)
    }

    func testFFMetadataListsChaptersInMilliseconds() {
        let text = AudiobookExporter.ffmetadata(title: "Sea; Stories", chapters: [("One", 1.5), ("Two = 2", 2)])
        XCTAssertTrue(text.hasPrefix(";FFMETADATA1\ntitle=Sea\\; Stories\n"))
        XCTAssertTrue(text.contains("START=0\nEND=1500\ntitle=One"))
        XCTAssertTrue(text.contains("START=1500\nEND=3500\ntitle=Two \\= 2"))
    }

    func testChapterAudioJoinsClipsAndAudiobookExportHasChapterMarkers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func tone(seconds: Double, rate: Int) -> Data {
            let count = Int(seconds * Double(rate))
            return NativeKokoroSpeechService.wavData(samples: (0..<count).map { Float(sin(Double($0) * 0.05)) * 0.3 }, sampleRate: rate)
        }

        // A 24 kHz clip and a 16 kHz clip become one 24 kHz chapter.
        let one = folder.appendingPathComponent("one.caf")
        let duration = try AudiobookExporter.writeChapter(clips: [tone(seconds: 1, rate: 24_000), tone(seconds: 0.5, rate: 16_000)], to: one)
        XCTAssertEqual(duration, 1.5, accuracy: 0.02)
        let two = folder.appendingPathComponent("two.caf")
        try AudiobookExporter.writeChapter(clips: [tone(seconds: 2, rate: 24_000)], to: two)

        guard AudiobookExporter.ffmpegURL != nil else { throw XCTSkip("ffmpeg isn't installed") }
        let book = folder.appendingPathComponent("Sea Stories.m4b")
        try await AudiobookExporter.exportM4B(chapters: [("The Harbor", one, 1.5), ("The Storm", two, 2)], title: "Sea Stories", to: book)

        let asset = AVURLAsset(url: book)
        let length = try await asset.load(.duration).seconds
        XCTAssertEqual(length, 3.5, accuracy: 0.15)
        // ffmpeg tags the chapter track's language as undetermined.
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locales.first ?? Locale(identifier: "und"), containingItemsWithCommonKeys: [])
        XCTAssertEqual(groups.count, 2)
        var titles: [String] = []
        for group in groups {
            let title = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            titles.append(try await title?.load(.stringValue) ?? "")
        }
        XCTAssertEqual(titles, ["The Harbor", "The Storm"])

        let mp3s = folder.appendingPathComponent("chapters")
        try await AudiobookExporter.exportChapterFiles(chapters: [("The Harbor", one, 1.5), ("The Storm", two, 2)], to: mp3s)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: mp3s.path).sorted(), ["01 The Harbor.mp3", "02 The Storm.mp3"])
    }

    @MainActor
    func testBookPlaysChapterByChapterAndHonorsTheSleepTimer() {
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "edge:en-US-AriaNeural"
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor(), playbackCoordinator: FakePlaybackCoordinating()))
        let book = Book(title: "Sea", source: "sea.md", chapters: [
            BookChapter(title: "One", text: "First chapter."),
            BookChapter(title: "Two", text: "Second chapter."),
            BookChapter(title: "Three", text: "Third chapter.")
        ])
        model.openBook(book)
        XCTAssertEqual(store.bookChapter, 0)
        XCTAssertEqual(model.inputText, "First chapter.")

        model.listenToChapter(resume: false)
        let firstJob = try? XCTUnwrap(store.playbackState.activeJobID)
        XCTAssertEqual(store.speechJobs.first?.text, "First chapter.")

        // The chapter ends on its own: the next one starts.
        model.speechPlaybackFinished(jobID: firstJob!)
        XCTAssertEqual(store.bookChapter, 1)
        XCTAssertEqual(store.speechJobs.first?.text, "Second chapter.")

        // With "end of chapter" set, the next ending stops instead.
        model.setSleepTimer(.endOfChapter)
        model.speechPlaybackFinished(jobID: store.playbackState.activeJobID!)
        XCTAssertEqual(store.bookChapter, 1)
        XCTAssertEqual(store.sleepTimer, .off)
        XCTAssertEqual(store.speechJobs.first?.text, "Second chapter.")
        try? FileManager.default.removeItem(at: book.folder)
    }

    // MARK: Read-along (X2)

    func testReadAlongSplitsWordsAndSentences() {
        let text = "Hello there. How are you? Fine!"
        let ns = text as NSString

        XCTAssertEqual(ReadAlong.units(in: text, mode: .word).map { ns.substring(with: $0) }, ["Hello", "there.", "How", "are", "you?", "Fine!"])
        XCTAssertEqual(ReadAlong.units(in: text, mode: .sentence).map { ns.substring(with: $0) }, ["Hello there.", "How are you?", "Fine!"])
        XCTAssertTrue(ReadAlong.units(in: text, mode: .off).isEmpty)
    }

    func testReadAlongMapsTimeToTextAndBack() {
        let segments = [ReadAlong.Segment(length: 100, duration: 10), ReadAlong.Segment(length: 50, duration: 5)]

        XCTAssertEqual(ReadAlong.position(elapsed: 5, segments: segments)?.segment, 0)
        XCTAssertEqual(ReadAlong.position(elapsed: 5, segments: segments)?.offset, 50)
        XCTAssertEqual(ReadAlong.position(elapsed: 12.5, segments: segments)?.segment, 1)
        XCTAssertEqual(ReadAlong.position(elapsed: 12.5, segments: segments)?.offset, 25)
        XCTAssertEqual(ReadAlong.position(elapsed: 99, segments: segments)?.offset, 49, "Past the end stays on the last character")
        XCTAssertEqual(ReadAlong.time(segment: 1, offset: 25, segments: segments), 12.5, accuracy: 0.001)
        // A segment whose clip hasn't loaded yet uses an estimate.
        XCTAssertEqual(ReadAlong.time(segment: 1, offset: 0, segments: [ReadAlong.Segment(length: 150, duration: nil), segments[1]]), 10, accuracy: 0.001)
    }

    func testReadAlongPassagesStayShortAndCoverTheText() {
        let text = (1...30).map { "Sentence number \($0) is here." }.joined(separator: " ")

        let passages = ReadAlong.passages(in: text, limit: 100)

        XCTAssertGreaterThan(passages.count, 5)
        XCTAssertTrue(passages.allSatisfy { $0.length <= 100 })
        XCTAssertEqual(passages.first?.location, 0)
        XCTAssertEqual(passages.last.map { $0.location + $0.length }, (text as NSString).length)
    }

    @MainActor
    func testReadAlongHighlightsTheWordBeingSpokenAndSeeksOnClick() {
        let playback = FakePlaybackCoordinating()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor(), playbackCoordinator: playback))
        store.readAlongMode = .word
        var first = SpeechSegment(index: 0, text: "One two three four.")
        first.durationSeconds = 4
        var second = SpeechSegment(index: 1, text: "Five six seven eight.")
        second.durationSeconds = 4
        let job = SpeechJob(text: "One two three four. Five six seven eight.", voiceID: "af_heart", segments: [first, second])
        store.speechJobs = [job]
        store.playback = PlaybackSnapshot(state: .playing, activeJobID: job.id, activeLogEntryID: nil, currentSegmentID: second.id, elapsedTime: 5.2, duration: 8, bufferedDuration: 8, statusMessage: nil)

        let state = model.readAlongState

        XCTAssertEqual(state?.passage, "Five six seven eight.")
        XCTAssertEqual(state.flatMap { $0.highlight }.map { ("Five six seven eight." as NSString).substring(with: $0) }, "six")
        XCTAssertEqual(state?.segmentIndex, 1)

        model.seekReadAlong(segmentIndex: 1, offset: 9)
        XCTAssertEqual(playback.lastSeek ?? -1, 4 + 4 * 9 / 21, accuracy: 0.001)

        store.readAlongMode = .off
        XCTAssertNil(model.readAlongState)
    }

    @MainActor
    func testReadAlongFollowsTheAppleVoicesOwnWordRanges() {
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        store.readAlongMode = .sentence
        let text = "First sentence here. Second one now."
        let job = SpeechJob(text: text, voiceID: "apple:x", segments: [SpeechSegment(index: 0, text: text)])
        store.speechJobs = [job]
        store.playback = PlaybackSnapshot(state: .playing, activeJobID: job.id, activeLogEntryID: nil, currentSegmentID: nil, elapsedTime: 0, duration: nil, bufferedDuration: 0, statusMessage: nil)
        store.appleSpokenRange = (text as NSString).range(of: "one")

        let state = model.readAlongState

        XCTAssertEqual(state.flatMap { $0.highlight }.map { (state!.passage as NSString).substring(with: $0) }, "Second one now.")
        XCTAssertEqual(state?.canSeek, false, "Apple's synthesizer can't jump")
    }

    // MARK: Text cleanup and pronunciations (X7)

    func testCleanupStripsMarkdownButKeepsTheWords() {
        let markdown = """
        # Release Notes
        - **Bold** and _italic_ and `code` words
        * A [link](https://example.com/page) and an ![chart](img.png)
        > Quoted line
        ---
        ```swift
        let x = 1
        ```
        """

        let spoken = TextNormalizer.clean(markdown)

        XCTAssertEqual(spoken, "Release Notes.\nBold and italic and code words\nA link and an chart\nQuoted line\n\n(code omitted)")
    }

    func testCleanupReadsLinksEmailsAndVersions() {
        XCTAssertEqual(
            TextNormalizer.clean("See https://www.github.com/alki/woadie, or mail hello@alki.example."),
            "See link to github dot com, or mail hello at alki dot example."
        )
        XCTAssertEqual(TextNormalizer.clean("Update to v2.1 or 3.0.4 today."), "Update to version 2 point 1 or version 3 point 0 point 4 today.")
        XCTAssertEqual(TextNormalizer.clean("Pi is 3.14 and costs $5.99."), "Pi is 3.14 and costs $5.99.", "Plain decimals and prices are left to the voice")
    }

    func testCleanupDropsCitationsAndJoinsWrappedLines() {
        XCTAssertEqual(TextNormalizer.clean("Speech synthesis is old.[1][23] It works.[citation needed]"), "Speech synthesis is old. It works.")
        XCTAssertEqual(
            TextNormalizer.clean("The harbor woke\nslowly that morning.\nGulls argued."),
            "The harbor woke slowly that morning.\nGulls argued."
        )
    }

    func testCleanupLeavesExpressionTagsDialogueAndHTMLLikeMathAlone() {
        let script = "Joe (cheerful): Hello [Laughter] there.\nJane: Hi! 2 < 3 and 5 > 4."

        XCTAssertEqual(TextNormalizer.clean(script), script)
    }

    func testCleanupStripsHTMLTagsAndCanBeTurnedOff() {
        XCTAssertEqual(TextNormalizer.clean("<p>Hello <b>world</b></p>"), "Hello world")
        var off = TextCleanupOptions()
        off.isEnabled = false
        XCTAssertEqual(TextNormalizer.clean("**raw**", options: off), "**raw**")
        var noLinks = TextCleanupOptions()
        noLinks.links = false
        XCTAssertEqual(TextNormalizer.clean("Go to https://a.example now", options: noLinks), "Go to https://a.example now")
    }

    func testPronunciationsSwapWholeWordsOnly() {
        let entries = [
            PronunciationEntry(word: "ALKI", sayAs: "Al-kee"),
            PronunciationEntry(word: "Woadie", sayAs: "/wˈOdi/")
        ]

        XCTAssertEqual(
            TextNormalizer.applyPronunciations("alki and ALKIcorp meet Woadie.", entries: entries, phonemesSupported: false),
            "Al-kee and ALKIcorp meet Woadie.",
            "Phoneme entries are skipped where the voice can't read them"
        )
        XCTAssertEqual(
            TextNormalizer.applyPronunciations("Hi Woadie.", entries: entries, phonemesSupported: true),
            "Hi [Woadie](/wˈOdi/)."
        )
    }

    func testPronunciationListRoundTripsThroughJSON() throws {
        let entries = [PronunciationEntry(word: "ALKI", sayAs: "Al-kee")]

        let imported = try PronunciationEntry.importJSON(PronunciationEntry.exportJSON(entries))

        XCTAssertEqual(imported.map(\.word), ["ALKI"])
        XCTAssertEqual(imported.map(\.sayAs), ["Al-kee"])
    }

    @MainActor
    func testSpokenTextUsesCleanupThenPronunciations() {
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "apple:x"
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        model.setPronunciations([PronunciationEntry(word: "ALKI", sayAs: "Al-kee")])

        XCTAssertEqual(model.spokenText(for: "**ALKI** rocks"), "Al-kee rocks")
    }

    // MARK: Document import (X4)

    func testPDFTextDropsRunningHeadersPageNumbersAndLineBreakHyphens() {
        let words = ["harbor", "gulls", "fog", "radio"]
        let pages = (1...4).map { page in
            let word = words[page - 1]
            return "The Long Road\nThe \(word) part of chapter one has an exam-\nple of a sentence about the \(word).\nSome more text about the \(word) follows here.\nAnd the \(word) paragraph keeps going for a while.\nIt ends on this line about the \(word).\n\(page)"
        }

        let text = DocumentImporter.pdfText(pages: pages)

        XCTAssertFalse(text.contains("The Long Road"), "A title repeated on every page is a running header")
        XCTAssertTrue(text.contains("example of a sentence"), "A hyphen split across a line break is joined")
        XCTAssertFalse(text.components(separatedBy: .newlines).contains("3"), "Bare page numbers are dropped")
        XCTAssertTrue(text.contains("Some more text about the fog follows here."))
        XCTAssertTrue(text.contains("It ends on this line about the radio."))
    }

    func testArticleExtractionKeepsTheStoryAndDropsTheChrome() {
        let html = """
        <html><head><title>Fallback</title><meta property="og:title" content="Gulls &amp; Boats">
        <style>p { color: red }</style><script>track()</script></head>
        <body><nav><a href="/">Home</a> <a href="/about">About us and more links</a></nav>
        <article><h1>Gulls &amp; Boats</h1><p>The quiet harbor woke slowly.</p><p>By noon the fog had lifted &#8212; at last.</p></article>
        <footer>Copyright 2026 and other footer words</footer></body></html>
        """

        let page = DocumentImporter.article(fromHTML: html)

        XCTAssertEqual(page.title, "Gulls & Boats")
        XCTAssertTrue(page.text.contains("The quiet harbor woke slowly."))
        XCTAssertTrue(page.text.contains("By noon the fog had lifted \u{2014} at last."))
        XCTAssertFalse(page.text.contains("About us"))
        XCTAssertFalse(page.text.contains("Copyright"))
        XCTAssertFalse(page.text.contains("track()"))
    }

    func testArticleExtractionFallsBackToParagraphsWithoutAnArticle() {
        let html = "<body><div><p>Short</p><p>This is a real paragraph with enough words to count as content.</p></div></body>"

        XCTAssertEqual(DocumentImporter.article(fromHTML: html).text, "This is a real paragraph with enough words to count as content.")
    }

    func testEPUBChaptersFollowTheSpineNotTheManifest() {
        let opf = """
        <manifest><item id="c2" href="text/two.xhtml" media-type="application/xhtml+xml"/>
        <item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
        """

        XCTAssertEqual(DocumentImporter.epubChapterPaths(opf: opf), ["text/one.xhtml", "text/two.xhtml"])
    }

    func testWebURLDetection() {
        XCTAssertEqual(DocumentImporter.webURL(in: "  https://example.com/story \n")?.host(), "example.com")
        XCTAssertNil(DocumentImporter.webURL(in: "read https://example.com now"))
        XCTAssertNil(DocumentImporter.webURL(in: "file:///etc/hosts"))
        XCTAssertNil(DocumentImporter.webURL(in: "just words"))
    }

    func testImportsRealPDFEPUBAndRTFFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // PDF: three pages with the same header and a page number.
        let pdfURL = folder.appendingPathComponent("book.pdf")
        try Self.writePDF(to: pdfURL, pages: (1...3).map { ["My Book", "Page \($0) has a sentence worth reading aloud.", "\($0)"] })
        let pdf = try await DocumentImporter.importDocument(at: pdfURL)
        XCTAssertTrue(pdf.text.contains("Page 2 has a sentence worth reading aloud."))
        XCTAssertFalse(pdf.text.contains("My Book"))

        // A PDF with no text at all reads as scanned.
        let scannedURL = folder.appendingPathComponent("scan.pdf")
        try Self.writePDF(to: scannedURL, pages: [[], []])
        do {
            _ = try await DocumentImporter.importDocument(at: scannedURL)
            XCTFail("Expected a scanned-PDF error")
        } catch let error as DocumentImportError {
            XCTAssertEqual(error, .scannedPDF)
        }

        // EPUB: container → OPF → two chapters in spine order.
        let book = folder.appendingPathComponent("epub-src")
        try FileManager.default.createDirectory(at: book.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: book.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: book.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try #"<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>"#
            .write(to: book.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <package><metadata><dc:title>Sea Stories</dc:title></metadata>
        <manifest><item id="b" href="b.xhtml"/><item id="a" href="a.xhtml"/></manifest>
        <spine><itemref idref="a"/><itemref idref="b"/></spine></package>
        """.write(to: book.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        try "<html><body><h1>One</h1><p>First chapter.</p></body></html>".write(to: book.appendingPathComponent("OEBPS/a.xhtml"), atomically: true, encoding: .utf8)
        try "<html><body><h1>Two</h1><p>Second chapter.</p></body></html>".write(to: book.appendingPathComponent("OEBPS/b.xhtml"), atomically: true, encoding: .utf8)
        let epubURL = folder.appendingPathComponent("stories.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", book.path, epubURL.path]
        try zip.run()
        zip.waitUntilExit()
        let epub = try await DocumentImporter.importDocument(at: epubURL)
        XCTAssertEqual(epub.title, "Sea Stories")
        XCTAssertEqual(epub.chapters.map(\.title), ["One", "Two"], "EPUB chapters keep their headings")
        let first = try XCTUnwrap(epub.text.range(of: "First chapter."))
        let second = try XCTUnwrap(epub.text.range(of: "Second chapter."))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)

        // RTF through NSAttributedString.
        let rtfURL = folder.appendingPathComponent("note.rtf")
        let rtf = NSAttributedString(string: "Rich text, read plainly.")
        try rtf.data(from: NSRange(location: 0, length: rtf.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            .write(to: rtfURL)
        let note = try await DocumentImporter.importDocument(at: rtfURL)
        XCTAssertEqual(note.text, "Rich text, read plainly.")
        XCTAssertEqual(note.title, "note")
    }

    func testImportsAWebPageArticle() async throws {
        let html = "<html><head><title>Harbor News</title></head><body><nav>Menu items go here</nav><article><p>The harbor woke slowly today.</p></article></body></html>"
        StubWebProtocol.body = Data(html.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWebProtocol.self]
        let page = try await DocumentImporter.importWebPage(URL(string: "https://news.example/story")!, session: URLSession(configuration: configuration))

        XCTAssertEqual(page.title, "Harbor News")
        XCTAssertEqual(page.text, "The harbor woke slowly today.")
        XCTAssertEqual(page.source, "news.example")
    }

    /// Writes a PDF whose pages hold the given lines of text, top to bottom.
    private static func writePDF(to url: URL, pages: [[String]]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 72, y: 720 - index * 300), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor
    func testTypingNotifiesOnlyReadersOfTheText() {
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        var textChanged = false
        var othersChanged = false
        withObservationTracking { _ = model.inputText } onChange: { textChanged = true }
        withObservationTracking {
            _ = model.voiceDropdownSections
            _ = model.engineStatusLabel
            _ = model.chatItems
            _ = model.cloudSettings
            _ = model.playback
        } onChange: { othersChanged = true }

        store.composerText = "Hello"

        XCTAssertTrue(textChanged)
        XCTAssertFalse(othersChanged, "A keystroke must not re-render the voice picker, status, log or settings")
    }

    @MainActor
    func testEngineStatusLabelFollowsEngineHealth() {
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "af_heart"
        store.engineStatus = .running
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        var changed = false
        withObservationTracking { _ = model.engineStatusLabel } onChange: { changed = true }

        var health = store.engineHealth
        health.consecutiveHealthFailures += 1
        store.engineHealth = health

        XCTAssertTrue(changed, "The supervisor's status text changes with the health summary")
    }

    @MainActor
    func testInputRowAndStatusRedrawFromStoreChanges() {
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "af_heart"
        store.engineStatus = .running
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        let input = Self.host(WoadieInputRow(model: model).frame(width: 600, height: 220))
        let status = Self.host(StatusIndicatorView(model: model).frame(width: 300, height: 60))

        let inputBefore = Self.render(input)
        store.composerText = "Typed after the first render."
        XCTAssertNotEqual(inputBefore, Self.render(input), "The text box must redraw when the text changes")

        let statusBefore = Self.render(status)
        store.engineStatus = .stopped
        XCTAssertNotEqual(statusBefore, Self.render(status), "The status label must redraw when the engine stops")
    }

    @MainActor
    private static func host<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        return host
    }

    @MainActor
    private static func render(_ host: NSView) -> Data {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.tiffRepresentation!
    }

    @MainActor
    func testVoicePickerIndexFollowsVoicesAndFavorites() {
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "af_sky"
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        store.voiceOptions = [
            VoiceOption(id: "af_heart", label: "Kokoro Heart", source: .kokoro),
            VoiceOption(id: "af_sky", label: "Kokoro Sky", source: .kokoro)
        ]

        XCTAssertEqual(model.selectedVoiceLabel, "Sky")
        XCTAssertFalse(model.voiceDropdownSections.map(\.title).contains("Favorites"))

        store.voiceFavorites.insert("af_sky")

        let favorites = model.voiceDropdownSections.first { $0.title == "Favorites" }
        XCTAssertEqual(favorites?.options.map(\.id), ["af_sky"])
        XCTAssertEqual(favorites?.options.first?.isFavorite, true)
    }

    @MainActor
    func testIdleStoppedKokoroEngineKeepsGenerateAvailable() {
        let store = AppStore()
        store.composerText = "Wake up"
        store.activeWorkspace.selectedVoiceID = "af_heart"
        store.engineStatus = .running
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))

        model.stopPythonKokoroEngineIfIdle()

        XCTAssertEqual(store.engineStatus, .stopped)
        XCTAssertTrue(model.isEngineOnStandby)
        XCTAssertEqual(model.engineStatusLabel, "Kokoro Standby")
        XCTAssertTrue(model.canSpeak)
        XCTAssertTrue(model.canEditText)
    }

    @MainActor
    func testManuallyStoppedKokoroEngineStillDisablesGenerate() {
        let store = AppStore()
        store.composerText = "Stay off"
        store.activeWorkspace.selectedVoiceID = "af_heart"
        store.engineStatus = .running
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))

        model.stopPythonKokoroEngineIfIdle()
        model.stopEngine()

        XCTAssertFalse(model.isEngineOnStandby)
        XCTAssertFalse(model.canSpeak)
    }

    @MainActor
    func testGenerateWakesIdleStoppedKokoroEngine() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        store.composerText = "Wake up"
        store.activeWorkspace.selectedVoiceID = "af_heart"
        store.engineStatus = .running
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))
        model.stopPythonKokoroEngineIfIdle()

        model.speak()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(supervisor.startCallCount, 1)
        XCTAssertEqual(store.playback.statusMessage, "Starting Kokoro…")
        model.stopEngine()
    }

    @MainActor
    func testPlaybackControlTogglesCachedAudioWithoutGeneratingAgain() {
        let playback = FakePlaybackCoordinating()
        let store = AppStore()
        store.playback.state = .playing
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                playbackCoordinator: playback
            )
        )

        model.togglePlayback()

        XCTAssertEqual(playback.toggleCallCount, 1)
    }

    @MainActor
    func testSelectedTextServiceProviderSpeaksPasteboardString() async {
        let localSpeech = FakeLocalSpeechSynthesizing()
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "apple:test"
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech
            )
        )
        let provider = SelectedTextServiceProvider(model: model)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Read this from another app.", forType: .string)
        var serviceError: NSString?

        provider.speakSelection(pasteboard, userData: nil, error: &serviceError)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(serviceError)
        XCTAssertEqual(localSpeech.spokenTexts, ["Read this from another app."])
        XCTAssertEqual(store.composerText, "Read this from another app.")
    }

    @MainActor
    func testMenuBarSpeakSelectedTextDoesNotSpeakWhenPermissionIsRequired() async {
        let localSpeech = FakeLocalSpeechSynthesizing()
        let selectedTextReader = FakeSelectedTextReader(result: .permissionRequired)
        let store = AppStore()
        store.composerText = "Keep this text"
        store.activeWorkspace.selectedVoiceID = "apple:test"
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech,
                selectedTextReader: selectedTextReader
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Stale clipboard text.", forType: .string)

        model.speakSelectedTextFromMenuBar()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(localSpeech.spokenTexts.isEmpty)
        XCTAssertEqual(store.composerText, "Keep this text")
        XCTAssertTrue(store.selectedTextPermissionRequired)
        XCTAssertEqual(selectedTextReader.promptRequestCount, 1)
        XCTAssertEqual(store.userMessage, "Accessibility access is required to read selected text.")
    }

    @MainActor
    func testMenuBarSpeakSelectedTextDoesNotSpeakWhenNothingIsSelected() async {
        let localSpeech = FakeLocalSpeechSynthesizing()
        let selectedTextReader = FakeSelectedTextReader(result: .noSelection)
        let store = AppStore()
        store.composerText = "Keep this text"
        store.activeWorkspace.selectedVoiceID = "apple:test"
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech,
                selectedTextReader: selectedTextReader
            )
        )

        model.speakSelectedTextFromMenuBar()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(localSpeech.spokenTexts.isEmpty)
        XCTAssertEqual(store.composerText, "Keep this text")
        XCTAssertFalse(store.selectedTextPermissionRequired)
        XCTAssertEqual(store.userMessage, "No text is selected in another app. Select text and try again.")
    }

    @MainActor
    func testMenuBarSpeakSelectedTextSpeaksCurrentSelection() async {
        let localSpeech = FakeLocalSpeechSynthesizing()
        let selectedTextReader = FakeSelectedTextReader(result: .selected("Fresh selected text."))
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "apple:test"
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech,
                selectedTextReader: selectedTextReader
            )
        )

        model.speakSelectedTextFromMenuBar()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(localSpeech.spokenTexts, ["Fresh selected text."])
        XCTAssertEqual(store.composerText, "Fresh selected text.")
        XCTAssertFalse(store.selectedTextPermissionRequired)
    }

    @MainActor
    func testFreshPasteboardReadRequiresChangeDuringCurrentAction() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Stale clipboard text.", forType: .string)
        let baseline = pasteboard.changeCount

        XCTAssertNil(SelectedTextReader.freshRead(from: pasteboard, after: baseline))

        pasteboard.clearContents()
        pasteboard.setString("Fresh selected text.", forType: .string)
        let read = SelectedTextReader.freshRead(from: pasteboard, after: baseline)

        XCTAssertEqual(read?.text, "Fresh selected text.")
        XCTAssertEqual(read?.changeCount, pasteboard.changeCount)
    }

    @MainActor
    func testPasteboardRestoreDoesNotOverwriteConcurrentCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard text.", forType: .string)
        let snapshot = SelectedTextReader.PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("Fresh selected text.", forType: .string)
        let selectionChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("Concurrent clipboard text.", forType: .string)

        XCTAssertFalse(snapshot.restore(to: pasteboard, ifUnchangedSince: selectionChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "Concurrent clipboard text.")
    }

    @MainActor
    func testPasteboardRestoreReinstatesOriginalWhenCopyIsStillCurrent() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Original clipboard text.", forType: .string)
        let snapshot = SelectedTextReader.PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("Fresh selected text.", forType: .string)
        let selectionChangeCount = pasteboard.changeCount

        XCTAssertTrue(snapshot.restore(to: pasteboard, ifUnchangedSince: selectionChangeCount))
        XCTAssertEqual(pasteboard.string(forType: .string), "Original clipboard text.")
    }

    @MainActor
    func testFinishedPlaybackRetainsClipForReplayAndUnblocksSpeak() {
        let playback = FakePlaybackCoordinating()
        let store = AppStore()
        store.composerText = "Generate another clip"
        store.engineStatus = .running
        store.playback = PlaybackSnapshot(
            state: .playing,
            activeJobID: UUID(),
            activeLogEntryID: UUID(),
            currentSegmentID: UUID(),
            elapsedTime: 1,
            duration: 1,
            bufferedDuration: 1,
            statusMessage: nil
        )
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                playbackCoordinator: playback
            )
        )

        playback.finish()

        XCTAssertEqual(store.playback.state, .stopped)
        XCTAssertNotNil(store.playback.activeLogEntryID)
        XCTAssertEqual(store.playback.elapsedTime, 0)
        XCTAssertTrue(model.canSpeak)
    }

    func testQueuePlaybackAppendsSegmentsAndPublishesCumulativeBuffer() throws {
        let firstURL = try makeTestAudioFile(sampleRate: 24_000, duration: 0.2)
        let secondURL = try makeTestAudioFile(sampleRate: 24_000, duration: 0.3)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let coordinator = AVAudioPlaybackCoordinator()
        var snapshots: [PlaybackTransportSnapshot] = []
        coordinator.onSnapshotChanged = { snapshots.append($0) }
        coordinator.prepare(characterCounts: [30, 45])
        try coordinator.append(audioURL: firstURL, segmentID: UUID(), index: 0)
        try coordinator.append(audioURL: secondURL, segmentID: UUID(), index: 1)

        XCTAssertEqual(snapshots.last?.bufferedDuration ?? 0, 0.5, accuracy: 0.02)
        coordinator.stop()
    }

    func testQueuePlaybackConvertsASegmentInADifferentFormat() throws {
        let firstURL = try makeTestAudioFile(sampleRate: 24_000, duration: 0.1)
        let secondURL = try makeTestAudioFile(sampleRate: 44_100, duration: 0.1)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let coordinator = AVAudioPlaybackCoordinator()
        coordinator.prepare(characterCounts: [15, 15])
        try coordinator.append(audioURL: firstURL, segmentID: UUID(), index: 0)

        // A fallback voice can answer at another sample rate; it's converted
        // to match instead of failing the job.
        let duration = try coordinator.append(audioURL: secondURL, segmentID: UUID(), index: 1)
        XCTAssertEqual(duration, 0.1, accuracy: 0.01)
        coordinator.stop()
    }

    func testPlaybackSpectrumAnalyzerProducesFiniteMagnitudesAndResets() {
        let analyzer = PlaybackSpectrumAnalyzer(sampleCount: 2048, outputBinCount: 128)
        var samples = [Float](repeating: 0, count: 2048)
        for index in samples.indices {
            samples[index] = index.isMultiple(of: 2) ? 0.35 : -0.35
        }

        let magnitudes = samples.withUnsafeBufferPointer { pointer in
            analyzer.analyze(channel: pointer.baseAddress!, frameLength: pointer.count)
        }

        XCTAssertEqual(magnitudes.count, 128)
        XCTAssertTrue(magnitudes.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(magnitudes.reduce(0, +), 0)

        analyzer.reset()
        let silence = [Float](repeating: 0, count: 2048)
        let resetMagnitudes = silence.withUnsafeBufferPointer { pointer in
            analyzer.analyze(channel: pointer.baseAddress!, frameLength: pointer.count)
        }

        XCTAssertEqual(resetMagnitudes, Array(repeating: 0, count: 128))
    }

    private func makeTestAudioFile(sampleRate: Double, duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let samples = buffer.floatChannelData?.pointee {
            for frame in 0..<Int(frameCount) {
                samples[frame] = sin(Float(frame) * 0.04) * 0.1
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testStartupSuccessStateCanRepresentRunningEngine() {
        var summary = EngineHealthSummary.stopped
        summary.status = .running
        summary.pid = 42
        summary.startedAt = Date()
        summary.lastSuccessfulHealthCheckAt = Date()

        XCTAssertEqual(summary.status, .running)
        XCTAssertEqual(summary.pid, 42)
        XCTAssertTrue(summary.status.isAvailableForRemoteSpeech)
    }

    func testStartupTimeoutCapturesStableDiagnosticFields() {
        let issue = EngineIssue(
            code: "engine.startup-timeout",
            title: "Engine Startup Timed Out",
            description: "The engine process started but did not become healthy.",
            probableCause: "Model loading is stuck or dependencies are missing.",
            subsystem: "engine.lifecycle",
            retryCount: 1,
            rawError: "deadline exceeded"
        )

        XCTAssertEqual(issue.code, "engine.startup-timeout")
        XCTAssertEqual(issue.subsystem, "engine.lifecycle")
        XCTAssertEqual(issue.retryCount, 1)
        XCTAssertEqual(issue.rawError, "deadline exceeded")
    }

    func testCrashDetectionStateSupportsControlledRestart() {
        var summary = EngineHealthSummary.stopped
        let issue = EngineIssue(
            code: "engine.unexpected-termination",
            title: "Engine Process Exited",
            description: "The local engine exited unexpectedly.",
            probableCause: "The server crashed or was killed externally.",
            subsystem: "engine.lifecycle",
            retryCount: 1
        )

        summary.status = .retrying
        summary.retryCount = 1
        summary.latestIssue = issue
        summary.recentIssues = [issue]

        XCTAssertEqual(summary.status, .retrying)
        XCTAssertEqual(summary.latestIssue?.code, "engine.unexpected-termination")
        XCTAssertLessThanOrEqual(summary.retryCount, AppConfig.maxEngineRestartAttempts)
    }

    func testShutdownOnAppTerminationStateIsStopped() {
        let supervisor = ProcessEngineSupervisor()

        supervisor.stop()

        XCTAssertEqual(supervisor.healthSummary.status, .stopped)
        XCTAssertNil(supervisor.processIdentifier)
        XCTAssertFalse(supervisor.isRunning)
    }

    func testLargeRequestIsReroutedIntoSegments() {
        let policy = EngineRequestPolicy(maxDirectCharacters: 20, maxSegmentCharacters: 12)
        let segments = policy.segments(for: "This is a long pasted request. It needs safe routing.")

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.text.count <= 250 })
    }

    func testDirectOversizedRequestIsRejectedBeforeNetworkUse() async {
        let service = KokoroSpeechGenerationService()
        let oversized = String(repeating: "A", count: AppConfig.maxDirectRequestCharacters + 1)

        do {
            _ = try await service.synthesize(text: oversized, voice: AppConfig.defaultVoice, jobID: UUID())
            XCTFail("Expected oversized direct request to fail before URLSession work.")
        } catch let error as AlkiSpeakError {
            XCTAssertEqual(error.code, "generation.oversized-direct-request")
            XCTAssertEqual(error.context["limit"], "\(AppConfig.maxDirectRequestCharacters)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testAppStartupDelegatesPortRecoveryToSupervisorWithoutShowingAlert() async {
        let supervisor = FakeEngineSupervisor()
        supervisor.portUsers = [123]
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(supervisor.startCalled)
        XCTAssertFalse(store.showPortInUseAlert)
        XCTAssertEqual(store.engineStatus, .starting)
        model.stopEngine()
    }

    @MainActor
    func testStartEngineIgnoresDuplicateRequestWhileStarting() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        model.startEngine()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(supervisor.startCallCount, 1)
        XCTAssertEqual(store.engineStatus, .starting)
        model.stopEngine()
    }

    @MainActor
    func testStopEngineIgnoresLateStartingCallback() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        model.stopEngine()

        var staleSummary = EngineHealthSummary.stopped
        staleSummary.status = .starting
        supervisor.emit(staleSummary)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.engineStatus, .stopped)
    }

    @MainActor
    func testStartEngineIgnoresLateStoppedCallbackWhileStartIsActive() async {
        let supervisor = FakeEngineSupervisor()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: supervisor))

        model.startEngine()
        supervisor.emit(.stopped)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.engineStatus, .starting)
        model.stopEngine()
    }

    // MARK: Voice grouping, favorites, availability

    func testVoiceGroupingPutsFavoritesAndRecentFirstThenOnDeviceAndOnline() {
        let voices = [
            VoiceOption(id: "apple:a", label: "Apple - Alex [en-US]", source: .apple, appleQuality: .highest),
            VoiceOption(id: "af_heart", label: "Kokoro - af_heart", source: .kokoro),
            VoiceOption(id: "af_sky", label: "Kokoro - af_sky", source: .kokoro),
            VoiceOption(id: "edge:en-US-AriaNeural", label: "Edge - en-US-AriaNeural", source: .edge),
        ]

        let sections = VoiceGrouping.sections(voices: voices, favorites: ["af_heart"], recent: ["af_sky", "missing"])

        XCTAssertEqual(sections.map(\.title), ["Favorites", "Recent", "On this Mac", "Online"])
        XCTAssertEqual(sections[0].voices.map(\.id), ["af_heart"])
        XCTAssertEqual(sections[1].voices.map(\.id), ["af_sky"], "Unknown recent IDs are skipped")
        XCTAssertEqual(sections[2].voices.map(\.id), ["af_heart", "af_sky", "apple:a"], "Neural voices before Apple's")
        XCTAssertEqual(sections[3].voices.map(\.id), ["edge:en-US-AriaNeural"])
    }

    func testVoiceGroupingMovesLowQualityAppleVoicesToTheEnd() {
        let voices = [
            VoiceOption(id: "apple:p", label: "Premium", source: .apple, appleQuality: .highest),
            VoiceOption(id: "apple:c", label: "Compact", source: .apple, appleQuality: .low),
            VoiceOption(id: "apple:u", label: "Ungraded", source: .apple),
        ]

        let sections = VoiceGrouping.sections(voices: voices, favorites: [])

        XCTAssertEqual(sections.map(\.title), ["On this Mac", "More Apple voices"])
        XCTAssertEqual(sections[0].voices.map(\.id), ["apple:p", "apple:u"])
        XCTAssertEqual(sections[1].voices.map(\.id), ["apple:c"])
    }

    func testVoiceGroupingOmitsEmptySections() {
        let voices = [VoiceOption(id: "af_heart", label: "Heart", source: .kokoro)]

        XCTAssertEqual(VoiceGrouping.sections(voices: voices, favorites: []).map(\.title), ["On this Mac"])
    }

    func testVoicesGetPlainNamesAndTags() {
        let apple = VoiceOption(id: "apple:x", label: "Apple - Samantha [en-US]", source: .apple, appleQuality: .highest)
        XCTAssertEqual(apple.name, "Samantha")
        XCTAssertEqual(apple.detail, "Apple · en-US · Premium")
        XCTAssertTrue(apple.isOnDevice)

        let kokoro = VoiceOption(id: "bm_george", label: "Kokoro - bm_george", source: .kokoro)
        XCTAssertEqual(kokoro.name, "George")
        XCTAssertEqual(kokoro.detail, "Kokoro · British English · Male")

        let edge = VoiceOption(id: "edge:en-US-AndrewMultilingualNeural", label: "Edge - x", source: .edge)
        XCTAssertEqual(edge.name, "Andrew")
        XCTAssertEqual(edge.detail, "Microsoft Edge · en-US")
        XCTAssertFalse(edge.isOnDevice)

        XCTAssertEqual(VoiceNaming.sampleText(for: VoiceOption(id: "ef_dora", label: "", source: .kokoro)), "Hola, soy Dora. Así suena mi voz.")
        XCTAssertEqual(VoiceNaming.sampleText(for: kokoro), "Hi, I'm George. This is how I sound.")
    }

    func testAddedVoicesGetPlainNames() {
        let preset = CloudVoice(providerID: CloudProvider.localMLX.id, model: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit", voice: "Ryan", label: "Qwen3 Ryan (local)")
        XCTAssertEqual(VoiceCatalogController.naming(for: preset).name, "Ryan")
        XCTAssertEqual(VoiceCatalogController.naming(for: preset).detail, "Qwen3-TTS 1.7B")

        let clone = CloudVoice(providerID: CloudProvider.localMLX.id, model: LocalVoiceCatalog.cloningModelID, voice: "", label: "My voice (local)", referenceAudioPath: "/tmp/r.wav", referenceText: "Hi")
        XCTAssertEqual(VoiceCatalogController.naming(for: clone).name, "My voice")
        XCTAssertEqual(VoiceCatalogController.naming(for: clone).detail, "Cloned · On this Mac")
    }

    func testVoiceSearchMatchesEveryWordAcrossNameAndTag() {
        let voices = [
            VoiceOption(id: "bf_emma", label: "Kokoro - bf_emma", source: .kokoro),
            VoiceOption(id: "af_bella", label: "Kokoro - af_bella", source: .kokoro),
        ]

        XCTAssertEqual(VoiceGrouping.search(voices, query: "british female").map(\.id), ["bf_emma"])
        XCTAssertEqual(VoiceGrouping.search(voices, query: "BELLA").map(\.id), ["af_bella"])
        XCTAssertEqual(VoiceGrouping.search(voices, query: "").count, 2)
    }

    @MainActor
    func testPickingAVoiceAddsItToRecent() {
        let store = AppStore()
        store.activeWorkspace.selectedVoiceID = "apple:start"
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        store.voiceOptions = [
            VoiceOption(id: "af_heart", label: "Kokoro - af_heart", source: .kokoro),
            VoiceOption(id: "af_sky", label: "Kokoro - af_sky", source: .kokoro)
        ]

        model.selectedVoice = "af_heart"
        model.selectedVoice = "af_sky"

        XCTAssertEqual(Array(store.recentVoiceIDs.prefix(2)), ["af_sky", "af_heart"])
        XCTAssertEqual(model.voiceSections.first { $0.id == VoiceGrouping.recentSectionID }?.voices.map(\.id).prefix(2), ["af_sky", "af_heart"])
    }

    func testEveryVoiceSourceIsSynthesisReady() {
        XCTAssertTrue(VoiceSource.api.isSynthesisSupported)
        XCTAssertTrue(VoiceSource.apple.isSynthesisSupported)
        XCTAssertTrue(VoiceSource.kokoro.isSynthesisSupported)
        XCTAssertTrue(VoiceSource.edge.isSynthesisSupported)
    }

    // MARK: Cloud voices

    @MainActor
    func testAddingCloudVoiceListsAndSelectsItAndSpeaksWithoutKokoro() {
        let settings = InMemoryCloudSpeechSettingsStore()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor(), cloudSpeechSettings: settings))

        model.addCloudVoice(provider: .localMLX, model: "kokoro", voice: "af_heart", label: "")

        let added = try! XCTUnwrap(settings.settings.voices.first)
        XCTAssertEqual(added.label, "Local mlx-audio · af_heart")
        XCTAssertEqual(model.selectedVoice, added.voiceID)
        let option = model.voiceOptions.first { $0.id == added.voiceID }
        XCTAssertEqual(option?.source, .api)
        XCTAssertEqual(option?.label, "Cloud - Local mlx-audio · af_heart")
        XCTAssertEqual(option?.isOnDevice, true, "A local mlx-audio voice runs on this Mac")
        XCTAssertEqual(option?.name, "Local mlx-audio · af_heart")
        XCTAssertTrue(model.voiceSections.first { $0.title == "On this Mac" }?.voices.contains { $0.id == added.voiceID } ?? false)

        model.inputText = "Hello"
        XCTAssertFalse(model.isEngineRunning)
        XCTAssertTrue(model.canSpeak, "Cloud voices must not wait on the Kokoro engine")
    }

    @MainActor
    func testRemovingSelectedCloudVoiceDropsItAndMovesSelection() {
        let settings = InMemoryCloudSpeechSettingsStore()
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor(), cloudSpeechSettings: settings))
        model.addCloudVoice(provider: .openAI, model: "gpt-4o-mini-tts", voice: "marin", label: "Marin")
        let voice = settings.settings.voices[0]
        model.toggleFavorite(voice.voiceID)

        model.removeCloudVoice(voice)

        XCTAssertTrue(settings.settings.voices.isEmpty)
        XCTAssertNotEqual(model.selectedVoice, voice.voiceID)
        XCTAssertFalse(model.voiceOptions.contains { $0.id == voice.voiceID })
        XCTAssertFalse(model.isFavorite(voice.voiceID))
    }

    @MainActor
    func testAddingLocalVoiceWarmsUpServerAndQuitStopsIt() async {
        let server = FakeLocalVoiceServer()
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor(), localVoiceServer: server))

        model.addCloudVoice(provider: .openRouter, model: "m", voice: "v", label: "")
        model.addCloudVoice(provider: .localMLX, model: "qwen", voice: "Ryan", label: "")
        for _ in 0..<50 where server.ensureCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(server.ensureCount, 1, "Only the local voice should start the server")

        model.shutDownLocalVoiceServer()
        XCTAssertEqual(server.stopCount, 1)
    }

    @MainActor
    func testLocalPresetAddsOnceWithItsLabelAndWarmsServer() async {
        let settings = InMemoryCloudSpeechSettingsStore()
        let server = FakeLocalVoiceServer()
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor(), cloudSpeechSettings: settings, localVoiceServer: server))
        let ming = LocalVoiceCatalog.models[0]
        let charlotte = ming.voices.first { $0.name == "UK_Charlotte" }!

        XCTAssertFalse(model.hasCloudVoice(provider: .localMLX, model: ming.id, voice: charlotte.name))
        model.addLocalPreset(model: ming, voice: charlotte)
        model.addLocalPreset(model: ming, voice: charlotte)

        XCTAssertEqual(settings.settings.voices.count, 1, "A second tap must not duplicate the voice")
        XCTAssertEqual(settings.settings.voices[0].label, "Ming UK Charlotte (local)")
        XCTAssertEqual(settings.settings.voices[0].providerID, CloudProvider.localMLX.id)
        XCTAssertTrue(model.hasCloudVoice(provider: .localMLX, model: ming.id, voice: charlotte.name))
        XCTAssertEqual(model.selectedVoice, settings.settings.voices[0].voiceID)
        for _ in 0..<50 where server.ensureCount == 0 { await Task.yield() }
        XCTAssertEqual(server.ensureCount, 1)
    }

    @MainActor
    func testDesignedVoiceAndExpressionTagsFollowTheSelectedModel() {
        let settings = InMemoryCloudSpeechSettingsStore()
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor(), cloudSpeechSettings: settings))
        let ming = LocalVoiceCatalog.models.first { $0.supportsVoiceDesign }!
        let qwen = LocalVoiceCatalog.models.first { !$0.supportsVoiceDesign }!

        model.addDesignedLocalVoice(model: qwen, description: "A pirate", label: "")
        XCTAssertTrue(settings.settings.voices.isEmpty, "Models without voice design must refuse a description")

        model.addDesignedLocalVoice(model: ming, description: "  A warm, gentle storyteller with a slow pace  ", label: "")
        let designed = settings.settings.voices[0]
        XCTAssertEqual(designed.instructions, "A warm, gentle storyteller with a slow pace")
        XCTAssertEqual(designed.label, "Designed · A warm, gentle storyteller with…")
        XCTAssertEqual(model.selectedVoice, designed.voiceID)
        XCTAssertEqual(model.selectedVoiceExpressionTags.count, 14)

        model.inputText = "Well"
        model.insertExpressionTag("Laughter")
        XCTAssertEqual(model.inputText, "Well [Laughter] ")
        model.insertExpressionTag("Sigh")
        XCTAssertEqual(model.inputText, "Well [Laughter] [Sigh] ")

        model.addLocalPreset(model: qwen, voice: qwen.voices[0])
        XCTAssertEqual(model.selectedVoiceExpressionTags, [], "Qwen has no inline cues")
    }

    @MainActor
    func testGeminiDialogueVoiceValidatesItsCast() {
        let settings = InMemoryCloudSpeechSettingsStore()
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor(), cloudSpeechSettings: settings))
        let flash = "gemini-3.8-flash-tts"

        model.addGeminiDialogueVoice(model: flash, speakers: [.init(name: "Joe", voice: "Puck"), .init(name: "joe", voice: "Kore")], label: "")
        model.addGeminiDialogueVoice(model: flash, speakers: [.init(name: "Dr: Anya", voice: "Puck"), .init(name: "Liam", voice: "Kore")], label: "")
        model.addGeminiDialogueVoice(model: flash, speakers: [.init(name: "Joe", voice: "NotAVoice"), .init(name: "Jane", voice: "Kore")], label: "")
        model.addGeminiDialogueVoice(model: flash, speakers: [.init(name: "Joe", voice: "Puck")], label: "")
        XCTAssertTrue(settings.settings.voices.isEmpty, "Duplicate names, colons, unknown voices and a one-person cast are rejected")
        XCTAssertNil(model.selectedDialogueSpeakers)

        model.addGeminiDialogueVoice(model: flash, speakers: [.init(name: " Joe ", voice: "Puck"), .init(name: "Jane", voice: "Kore")], label: "")
        let voice = settings.settings.voices[0]
        XCTAssertEqual(voice.label, "Gemini dialogue · Joe & Jane")
        XCTAssertEqual(voice.speakers, [.init(name: "Joe", voice: "Puck"), .init(name: "Jane", voice: "Kore")])
        XCTAssertEqual(model.selectedDialogueSpeakers?.map(\.name), ["Joe", "Jane"])
        XCTAssertEqual(model.voiceOptions.first { $0.id == voice.voiceID }?.source, .api)
    }

    @MainActor
    func testNativeKokoroTurnsOnAndOffInTheVoicePicker() async {
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        XCTAssertEqual(model.nativeKokoroState, .off)
        XCTAssertFalse(model.voiceOptions.contains { $0.source == .kokoroNative })

        model.enableNativeKokoro()
        for _ in 0..<200 where model.nativeKokoroState != .ready(voiceCount: 2) { await Task.yield() }
        XCTAssertEqual(model.nativeKokoroState, .ready(voiceCount: 2))
        let heart = model.voiceOptions.first { $0.id == "kokoro-native:af_heart" }
        XCTAssertEqual(heart?.label, "Kokoro Native - af_heart")
        XCTAssertEqual(heart?.source, .kokoroNative)
        XCTAssertEqual(heart?.name, "Heart")
        XCTAssertEqual(heart?.detail, "Kokoro (Neural Engine) · American English · Female")
        let onDevice = model.voiceSections.first { $0.id == VoiceGrouping.onDeviceSectionID }
        XCTAssertTrue(onDevice?.voices.contains { $0.id == "kokoro-native:af_heart" } ?? false)

        model.selectedVoice = "kokoro-native:af_heart"
        model.inputText = "Hello"
        XCTAssertFalse(model.isEngineRunning)
        XCTAssertTrue(model.canSpeak, "Native Kokoro must not wait on the Python engine")

        model.disableNativeKokoro()
        XCTAssertEqual(model.nativeKokoroState, .off)
        XCTAssertFalse(model.voiceOptions.contains { $0.source == .kokoroNative })
        XCTAssertNotEqual(model.selectedVoice, "kokoro-native:af_heart")
    }

    @MainActor
    func testAddingLocalVoicePreparesItsModelInTheBackground() async {
        let server = FakeLocalVoiceServer()
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor(), localVoiceServer: server))
        let ming = LocalVoiceCatalog.models[0]

        model.addLocalPreset(model: ming, voice: ming.voices[0])
        XCTAssertEqual(model.localModelStates[ming.id], .preparing)
        for _ in 0..<100 where model.localModelStates[ming.id] != nil { await Task.yield() }

        XCTAssertEqual(server.preparedModels, [ming.id])
        XCTAssertNil(model.localModelStates[ming.id], "Cleared once the model is ready")
    }

    @MainActor
    func testExpressionTagsGoAtTheCursor() {
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        model.inputText = "Hello there"

        var cursor = model.insertExpressionTag("Laughter", replacing: 5..<5)
        XCTAssertEqual(model.inputText, "Hello [Laughter] there")
        XCTAssertEqual(cursor, 16, "Cursor lands after the tag and its space")

        cursor = model.insertExpressionTag("Sigh", replacing: 0..<5)
        XCTAssertEqual(model.inputText, "[Sigh] [Laughter] there", "A selection is replaced")
        XCTAssertEqual(cursor, 6)

        model.inputText = "Hi"
        model.insertExpressionTag("Cough", replacing: 99..<120)
        XCTAssertEqual(model.inputText, "Hi [Cough] ", "Out-of-range positions clamp to the end")
    }

    @MainActor
    func testCloudAPIKeyRoundTripsThroughSecretStore() {
        let secrets = InMemorySecretStore()
        let model = AppModel(store: AppStore(), dependencies: .test(engineSupervisor: FakeEngineSupervisor(), secretStore: secrets))

        XCTAssertFalse(model.hasCloudAPIKey(for: .openRouter))
        model.setCloudAPIKey("  sk-or-123  ", for: .openRouter)
        XCTAssertEqual(secrets.secrets["openrouter"], "sk-or-123")
        XCTAssertTrue(model.hasCloudAPIKey(for: .openRouter))
        model.setCloudAPIKey("", for: .openRouter)
        XCTAssertFalse(model.hasCloudAPIKey(for: .openRouter))
    }

    func testSelectionPreservedWhenStillPresentEvenIfUnavailable() {
        let voices = [
            VoiceOption(id: "af_heart", label: "Heart", source: .kokoro, isAvailable: false),
            VoiceOption(id: "apple:a", label: "A", source: .apple),
        ]

        XCTAssertEqual(VoiceSelection.resolved(current: "af_heart", in: voices, fallback: "x"), "af_heart")
    }

    func testSelectionFallsBackToFirstAvailableWhenMissing() {
        let voices = [
            VoiceOption(id: "edge:x", label: "Edge", source: .edge, isAvailable: false),
            VoiceOption(id: "apple:a", label: "A", source: .apple, isAvailable: true),
        ]

        XCTAssertEqual(VoiceSelection.resolved(current: "gone", in: voices, fallback: "fb"), "apple:a")
    }

    func testSelectionFallsBackToDefaultWhenCatalogEmpty() {
        XCTAssertEqual(VoiceSelection.resolved(current: "x", in: [], fallback: "af_heart"), "af_heart")
    }

    func testVoiceFavoritesPersistAcrossStores() {
        let suite = "VoiceFavorites-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        VoiceFavoritesStore(defaults: defaults).save(["af_heart", "apple:a"])

        XCTAssertEqual(VoiceFavoritesStore(defaults: defaults).load(), ["af_heart", "apple:a"])
    }

    // MARK: Query resource usage

    @MainActor
    func testStopPlaybackFinishesResourceSampling() {
        let localSpeech = FakeLocalSpeechSynthesizing()
        let store = AppStore()
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech
            )
        )
        store.selectedVoiceID = "apple:test"
        store.composerText = "Capture resource usage while local speech is playing."

        model.speak()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        model.stopPlayback()

        XCTAssertNotNil(store.lastQueryResourceUsage)
        XCTAssertGreaterThan(store.lastQueryResourceUsage?.sampleCount ?? 0, 0)
    }

    @MainActor
    func testLocalSpeechFailureFinishesResourceSampling() {
        let localSpeech = ThrowingLocalSpeechSynthesizing(delayBeforeThrow: 0.7)
        let store = AppStore()
        let model = AppModel(
            store: store,
            dependencies: .test(
                engineSupervisor: FakeEngineSupervisor(),
                localSpeechService: localSpeech
            )
        )
        store.selectedVoiceID = "apple:test"
        store.composerText = "Fail after collecting resource usage."

        model.speak()
        RunLoop.current.run(until: Date().addingTimeInterval(0.9))

        XCTAssertEqual(store.playback.state, .failed)
        XCTAssertFalse(model.isResourceSamplingActiveForTesting)
    }

    func testQueryResourceUsageAveragesSamplesAndTracksPeak() {
        let samples = [
            SystemResourceSnapshot(cpuPercent: 20, ramUsedMB: 1000, ramAvailableMB: 0),
            SystemResourceSnapshot(cpuPercent: 40, ramUsedMB: 1400, ramAvailableMB: 0),
        ]

        let usage = QueryResourceUsage(samples: samples)

        XCTAssertEqual(usage?.sampleCount, 2)
        XCTAssertEqual(usage?.averageCPUPercent ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(usage?.averageRAMUsedMB ?? 0, 1200, accuracy: 0.001)
        XCTAssertEqual(usage?.peakRAMUsedMB ?? 0, 1400, accuracy: 0.001)
    }

    func testQueryResourceUsageNilForEmptySamples() {
        XCTAssertNil(QueryResourceUsage(samples: []))
    }

    func testPerformanceDiagnosticRecorderWritesSamplesSpikesAndSummary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var tick: TimeInterval = 0
        let recorder = FilePerformanceDiagnosticRecorder(
            directory: directory,
            thresholds: PerformanceDiagnosticThresholds(
                cpuPercent: 80,
                ramAvailableMB: 500,
                processMemoryMB: 512
            ),
            dateProvider: {
                tick += 1
                return Date(timeIntervalSince1970: tick)
            }
        )

        recorder.startSession(context: ["test": "true"])
        recorder.recordSample(
            phase: .remoteGeneration,
            jobID: nil,
            system: SystemResourceSnapshot(cpuPercent: 20, ramUsedMB: 1000, ramAvailableMB: 2000),
            process: ResourceSnapshot(capturedAt: Date(), cpuPercent: nil, memoryBytes: 128 * 1_048_576, engineProcessID: 99, port: 7777),
            context: ["segment": "0"]
        )
        recorder.recordSample(
            phase: .playback,
            jobID: nil,
            system: SystemResourceSnapshot(cpuPercent: 95, ramUsedMB: 3000, ramAvailableMB: 250),
            process: ResourceSnapshot(capturedAt: Date(), cpuPercent: nil, memoryBytes: 900 * 1_048_576, engineProcessID: 99, port: 7777),
            context: ["segment": "0"]
        )
        recorder.finishSession(context: ["result": "done"])
        recorder.flush()

        let log = try String(contentsOf: recorder.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("\"kind\":\"sample\""))
        XCTAssertTrue(log.contains("\"kind\":\"spike\""))
        XCTAssertTrue(log.contains("\"phase\":\"playback\""))

        let summary = try JSONDecoder().decode(
            PerformanceDiagnosticSummary.self,
            from: Data(contentsOf: recorder.summaryURL)
        )
        XCTAssertEqual(summary.sampleCount, 2)
        XCTAssertEqual(summary.spikeCount, 1)
        XCTAssertEqual(summary.topCPUPhase?.phase, .playback)
        XCTAssertEqual(summary.topProcessMemoryPhase?.phase, .playback)
    }

    func testProcessTelemetryCaptureIncludesCurrentProcessMemory() {
        let snapshot = ProcessTelemetryService().capture(engineProcessID: 123)

        XCTAssertEqual(snapshot.engineProcessID, 123)
        XCTAssertGreaterThan(snapshot.memoryBytes ?? 0, 0)
    }

    func testLegacyQueryStatsDecodesWithoutResourceUsage() throws {
        let json = """
        {
          "generationTimeSeconds": 1.5,
          "fileSizeBytes": 2048,
          "characterCount": 42,
          "segmentCount": 2,
          "resourceBefore": {"cpuPercent": 0, "ramUsedMB": 0, "ramAvailableMB": 0},
          "resourceAfter": {"cpuPercent": 0, "ramUsedMB": 0, "ramAvailableMB": 0}
        }
        """.data(using: .utf8)!

        let stats = try JSONDecoder().decode(QueryStats.self, from: json)

        XCTAssertNil(stats.resourceUsage)
        XCTAssertEqual(stats.characterCount, 42)
        XCTAssertNil(stats.tokenCount)
    }

    // MARK: Playback tuning

    func testPlaybackTuningClampsToRanges() {
        let fast = PlaybackTuning(speed: 5, pitch: 99)
        XCTAssertEqual(fast.speed, PlaybackTuning.speedRange.upperBound)
        XCTAssertEqual(fast.pitch, PlaybackTuning.pitchRange.upperBound)

        let slow = PlaybackTuning(speed: 0.1, pitch: -99)
        XCTAssertEqual(slow.speed, PlaybackTuning.speedRange.lowerBound)
        XCTAssertEqual(slow.pitch, PlaybackTuning.pitchRange.lowerBound)
    }

    func testPlaybackTuningDefaultIsNeutral() {
        XCTAssertEqual(PlaybackTuning.default.speed, 1.0)
        XCTAssertEqual(PlaybackTuning.default.pitch, 0)
        XCTAssertTrue(PlaybackTuning.default.isDefault)
    }

    func testPlaybackTuningKeepsPitchButStartsAtNormalSpeed() {
        let suite = "Tuning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        PlaybackTuning(speed: 1.25, pitch: -3).save(to: defaults)
        let loaded = PlaybackTuning.load(from: defaults)

        XCTAssertEqual(loaded.speed, 1.0, accuracy: 0.0001)
        XCTAssertEqual(loaded.pitch, -3, accuracy: 0.0001)
    }

    func testPlaybackTuningIgnoresAndClearsSavedSpeeds() {
        let suite = "Tuning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in PlaybackTuning.legacySpeedDefaultsKeys {
            defaults.set(1.75, forKey: key)
        }

        let loaded = PlaybackTuning.load(from: defaults)

        XCTAssertEqual(loaded.speed, 1.0, accuracy: 0.0001)
        for key in PlaybackTuning.legacySpeedDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    @MainActor
    func testSetPlaybackSpeedClampsAndForwardsToCoordinator() {
        let playback = FakePlaybackCoordinating()
        let store = AppStore()
        let model = AppModel(
            store: store,
            dependencies: .test(engineSupervisor: FakeEngineSupervisor(), playbackCoordinator: playback)
        )

        model.setPlaybackSpeed(5.0)

        XCTAssertEqual(model.playbackTuning.speed, PlaybackTuning.speedRange.upperBound)
        XCTAssertEqual(playback.lastTuning?.speed, PlaybackTuning.speedRange.upperBound)
    }

    func testPlaybackTuningDoesNotRewriteQueuedClipURLs() throws {
        let url = try makeTestAudioFile(sampleRate: 24_000, duration: 0.2)
        defer { try? FileManager.default.removeItem(at: url) }

        let coordinator = AVAudioPlaybackCoordinator()
        coordinator.prepare(characterCounts: [30])
        try coordinator.append(audioURL: url, segmentID: UUID(), index: 0)
        let before = coordinator.queuedAudioURLs

        coordinator.applyTuning(PlaybackTuning(speed: 1.5, pitch: 4))

        XCTAssertEqual(coordinator.queuedAudioURLs, before)
        XCTAssertEqual(coordinator.queuedAudioURLs, [url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        coordinator.stop()
    }

    // MARK: Storage inventory

    func testClipInventorySortsByEachField() {
        let now = Date()
        let items = [
            ClipInventoryItem(id: UUID(), displayName: "Banana", text: "b", voice: "af_sky", model: "Kokoro", createdAt: now.addingTimeInterval(100), durationSeconds: 5, fileSizeBytes: 300, segmentRelativePaths: []),
            ClipInventoryItem(id: UUID(), displayName: "apple", text: "a", voice: "af_heart", model: "Kokoro", createdAt: now, durationSeconds: 2, fileSizeBytes: 900, segmentRelativePaths: []),
        ]

        XCTAssertEqual(ClipInventory.sorted(items, by: .name).map(\.displayName), ["apple", "Banana"])
        XCTAssertEqual(ClipInventory.sorted(items, by: .date).map(\.displayName), ["apple", "Banana"])
        XCTAssertEqual(ClipInventory.sorted(items, by: .duration).map(\.displayName), ["apple", "Banana"])
        XCTAssertEqual(ClipInventory.sorted(items, by: .voice).map(\.displayName), ["apple", "Banana"])
        XCTAssertEqual(ClipInventory.sorted(items, by: .size).map(\.displayName), ["Banana", "apple"])
        XCTAssertEqual(ClipInventory.sorted(items, by: .name, ascending: false).map(\.displayName), ["Banana", "apple"])
    }

    func testOrphanedClipPathsAreOnDiskButUnreferenced() {
        let onDisk: Set<String> = ["a.wav", "b.wav", "c.wav"]
        let referenced: Set<String> = ["b.wav"]

        XCTAssertEqual(ClipInventory.orphanedClipPaths(onDisk: onDisk, referenced: referenced), ["a.wav", "c.wav"])
    }

    func testNoOrphansWhenAllReferenced() {
        let paths: Set<String> = ["a.wav"]

        XCTAssertTrue(ClipInventory.orphanedClipPaths(onDisk: paths, referenced: paths).isEmpty)
    }

    @MainActor
    func testClipInventoryMapsEntriesUsingDisplayNameFallback() {
        let entry = SpeechEntry(
            textContent: "Hello world",
            voice: "af_heart",
            totalDurationSeconds: 3,
            stats: QueryStats(
                tokenCount: 1,
                generationTimeSeconds: 0,
                fileSizeBytes: 512,
                characterCount: 11,
                segmentCount: 1,
                resourceBefore: .empty,
                resourceAfter: .empty
            )
        )

        let items = ClipInventory.items(from: [entry])

        XCTAssertEqual(items.first?.displayName, "Hello world")
        XCTAssertEqual(items.first?.fileSizeBytes, 512)
    }

    @MainActor
    func testRenameUpdatesDisplayNameWithoutChangingText() throws {
        let store = try SpeechEntryStore(
            container: ModelContainer(
                for: SpeechEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
        let entry = SpeechEntry(textContent: "Original transcript", voice: "af_heart")
        try store.insert(entry)

        try store.rename(entry, to: "My Clip")
        XCTAssertEqual(entry.displayName, "My Clip")
        XCTAssertEqual(entry.textContent, "Original transcript")
        XCTAssertEqual(entry.resolvedDisplayName, "My Clip")

        try store.rename(entry, to: "   ")
        XCTAssertNil(entry.displayName)
        XCTAssertEqual(entry.resolvedDisplayName, "Original transcript")
    }

    @MainActor
    func testDeleteRemovesEntryFromStore() throws {
        let store = try SpeechEntryStore(
            container: ModelContainer(
                for: SpeechEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
        let entry = SpeechEntry(textContent: "Delete me", voice: "af_heart")
        try store.insert(entry)
        XCTAssertEqual(try store.fetchAll().count, 1)

        try store.delete(entry)

        XCTAssertEqual(try store.fetchAll().count, 0)
    }
}

private actor QueueRecorder {
    private(set) var events: [String] = []

    func started(_ index: Int) {
        events.append("start-\(index)")
    }

    func finished(_ index: Int) {
        events.append("finish-\(index)")
    }

    func ready(_ index: Int) {
        events.append("ready-\(index)")
    }
}

private final class FakeEngineSupervisor: EngineSupervising {
    var isRunning = false
    var processIdentifier: Int32?
    var engineState: EngineState = .unreachable
    var healthSummary: EngineHealthSummary = .stopped
    var onEngineStateChanged: ((EngineState) -> Void)?
    var onHealthChanged: ((EngineHealthSummary) -> Void)?
    var onIssue: ((EngineIssue) -> Void)?
    var portUsers: [Int32] = []
    var startCalled = false
    var startCallCount = 0

    func start() throws {
        startCalled = true
        startCallCount += 1
    }

    func restart() throws {
        startCalled = true
        startCallCount += 1
    }

    func emit(_ summary: EngineHealthSummary) {
        healthSummary = summary
        processIdentifier = summary.pid
        isRunning = summary.pid != nil
        onHealthChanged?(summary)
    }

    func stop() {}
    func noteRequestStarted(jobID: UUID) {}
    func noteRequestFinished(jobID: UUID) {}
    func findListeningPidsOnEnginePort() -> [Int32] { portUsers }
    func terminatePortUsers(_ pids: [Int32]) async {}
}

private final class FakeSpeechGenerating: SpeechGenerating {
    func checkHealth() async -> Bool { false }
    func fetchVoices() async throws -> [String] { [] }
    func synthesize(text: String, voice: String, jobID: UUID?) async throws -> SpeechGenerationResult {
        SpeechGenerationResult(audioData: Data(), latencyMs: nil, charCount: text.count)
    }
}

private final class FakePlaybackCoordinating: PlaybackCoordinating {
    var onSnapshotChanged: ((PlaybackTransportSnapshot) -> Void)?
    var onFinished: (() -> Void)?
    private(set) var toggleCallCount = 0
    private(set) var lastTuning: PlaybackTuning?
    func prepare(characterCounts: [Int]) {}
    func append(audioURL: URL, segmentID: UUID, index: Int) throws -> TimeInterval { 0 }
    func finishEnqueuing() {}
    private(set) var lastSeek: TimeInterval?
    func seek(to globalTime: TimeInterval) -> Bool {
        lastSeek = globalTime
        return true
    }
    func togglePlayback() { toggleCallCount += 1 }
    func stop() {}
    func applyTuning(_ tuning: PlaybackTuning) { lastTuning = tuning }

    func finish() {
        onFinished?()
    }
}

private final class FakeLocalSpeechSynthesizing: LocalSpeechSynthesizing {
    var voiceOptions: [VoiceOption] = [VoiceOption(id: "apple:test", label: "Apple Test", isLocal: true)]
    private(set) var spokenTexts: [String] = []
    func refreshVoices() {}
    func speak(text: String, voiceID: String) throws {
        spokenTexts.append(text)
    }
    func stop() {}
}

private final class ThrowingLocalSpeechSynthesizing: LocalSpeechSynthesizing {
    var voiceOptions: [VoiceOption] = [VoiceOption(id: "apple:test", label: "Apple Test", isLocal: true)]
    private let delayBeforeThrow: TimeInterval

    init(delayBeforeThrow: TimeInterval) {
        self.delayBeforeThrow = delayBeforeThrow
    }

    func refreshVoices() {}

    func speak(text: String, voiceID: String) throws {
        RunLoop.current.run(until: Date().addingTimeInterval(delayBeforeThrow))
        throw AlkiSpeakError.playback(
            code: "test.local-speech",
            title: "Local Speech Failed",
            message: "Synthetic local speech failure.",
            recoverySuggestion: "Retry."
        )
    }

    func stop() {}
}

private final class FakeTelemetryCapturing: TelemetryCapturing {
    func capture(engineProcessID: Int32?) -> ResourceSnapshot { .empty }
}

@MainActor
private final class FakeSelectedTextReader: SelectedTextReading {
    var result: SelectedTextReadResult
    private(set) var promptRequestCount = 0
    private(set) var settingsOpenCount = 0

    init(result: SelectedTextReadResult) {
        self.result = result
    }

    func readFocusedSelection() async -> SelectedTextReadResult {
        result
    }

    func requestAccessibilityPrompt() {
        promptRequestCount += 1
    }

    func openAccessibilitySettings() {
        settingsOpenCount += 1
    }
}

private final class FakeWorkspaceStore: ActiveWorkspacePersisting {
    func loadActiveWorkspace() throws -> WorkspaceSession? { nil }
    func saveActiveWorkspace(_ workspace: WorkspaceSession) throws {}
}

private final class FakeLogStore: SavedLogPersisting {
    func loadLogs(for workspaceID: UUID) throws -> [SavedLogEntry] { [] }
    func saveLog(_ entry: SavedLogEntry, workspaceID: UUID) throws {}
    func replaceLogs(_ entries: [SavedLogEntry], workspaceID: UUID) throws {}
}

private final class FakeClipStore: SegmentedClipStoring {
    func writeClip(data: Data, segmentID: UUID, workspaceID: UUID) throws -> URL {
        URL(fileURLWithPath: "/tmp/\(segmentID.uuidString).wav")
    }

    func removeClip(segmentID: UUID, workspaceID: UUID) throws {}
}

private final class FakePackageStore: SpeechPackageImportExporting {
    func exportPackage(_ package: SavedSpeechPackage) throws -> URL {
        URL(fileURLWithPath: "/tmp/\(package.id.uuidString).alkispeak")
    }

    func importPackage(from url: URL) throws -> SavedSpeechPackage {
        SavedSpeechPackage(name: "Test", workspaceID: UUID(), jobs: [], logEntries: [])
    }
}

@MainActor
private extension AppDependencies {
    static func test(
        engineSupervisor: EngineSupervising,
        playbackCoordinator: PlaybackCoordinating = FakePlaybackCoordinating(),
        localSpeechService: LocalSpeechSynthesizing = FakeLocalSpeechSynthesizing(),
        selectedTextReader: SelectedTextReading? = nil,
        cloudSpeechService: SpeechGenerating? = nil,
        cloudSpeechSettings: CloudSpeechSettingsStoring = InMemoryCloudSpeechSettingsStore(),
        secretStore: SecretStoring = InMemorySecretStore(),
        localVoiceServer: LocalVoiceServerEnsuring = FakeLocalVoiceServer(),
        elevenLabsCatalog: ElevenLabsCatalogFetching = FakeElevenLabsCatalog(),
        cartesiaVoices: CartesiaVoiceFetching = FakeCartesiaVoices(),
        nativeKokoroService: NativeKokoroSpeechService = NativeKokoroSpeechService(
            defaults: UserDefaults(suiteName: "WoadieTests.native.\(UUID().uuidString)")!,
            loadModel: { FakeKokoroModel() }
        )
    ) -> AppDependencies {
        AppDependencies(
            engineSupervisor: engineSupervisor,
            generationService: FakeSpeechGenerating(),
            edgeSpeechService: FakeSpeechGenerating(),
            cloudSpeechService: cloudSpeechService ?? FakeSpeechGenerating(),
            cloudSpeechSettings: cloudSpeechSettings,
            secretStore: secretStore,
            localVoiceServer: localVoiceServer,
            elevenLabsCatalog: elevenLabsCatalog,
            cartesiaVoices: cartesiaVoices,
            nativeKokoroService: nativeKokoroService,
            playbackCoordinator: playbackCoordinator,
            localSpeechService: localSpeechService,
            selectedTextReader: selectedTextReader ?? FakeSelectedTextReader(result: .noSelection),
            telemetryService: FakeTelemetryCapturing(),
            performanceDiagnostics: NullPerformanceDiagnosticRecorder(),
            workspaceStore: FakeWorkspaceStore(),
            logStore: FakeLogStore(),
            clipStore: FakeClipStore(),
            packageStore: FakePackageStore(),
            speechEntryStore: try! SpeechEntryStore(
                container: ModelContainer(
                    for: SpeechEntry.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            ),
            speechEntryArchiveService: SpeechEntryArchiveService()
        )
    }
}

final class CPULoadTests: XCTestCase {
    func testPercentUsesTheChangeSinceTheLastReading() {
        // Since boot this core is 10% busy, but between readings it was 50% busy.
        let before = [CPULoad.Ticks(user: 100, system: 0, nice: 0, idle: 900)]
        let after = [CPULoad.Ticks(user: 150, system: 0, nice: 0, idle: 950)]

        XCTAssertEqual(CPULoad.percent(from: before, to: after) ?? -1, 50, accuracy: 0.001)
    }

    func testPercentSurvivesCounterWraparound() {
        let before = [CPULoad.Ticks(user: UInt32.max - 9, system: 0, nice: 0, idle: UInt32.max - 9)]
        let after = [CPULoad.Ticks(user: 20, system: 0, nice: 0, idle: 20)]

        XCTAssertEqual(CPULoad.percent(from: before, to: after) ?? -1, 50, accuracy: 0.001)
    }

    func testPercentAddsUpEveryCore() {
        let before = [
            CPULoad.Ticks(user: 0, system: 0, nice: 0, idle: 0),
            CPULoad.Ticks(user: 0, system: 0, nice: 0, idle: 0)
        ]
        let after = [
            CPULoad.Ticks(user: 80, system: 20, nice: 0, idle: 0),
            CPULoad.Ticks(user: 0, system: 0, nice: 0, idle: 100)
        ]

        XCTAssertEqual(CPULoad.percent(from: before, to: after) ?? -1, 50, accuracy: 0.001)
    }

    func testPercentIsNilWithoutAnEarlierReadingOrElapsedTicks() {
        let ticks = [CPULoad.Ticks(user: 5, system: 5, nice: 0, idle: 5)]

        XCTAssertNil(CPULoad.percent(from: [], to: ticks))
        XCTAssertNil(CPULoad.percent(from: ticks, to: ticks))
    }
}

@MainActor
final class GlobalHotKeyTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        let name = "GlobalHotKeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultsAreOptionEscapeAndOptionShiftEscape() {
        let service = GlobalHotKeyService(defaults: isolatedDefaults())
        XCTAssertEqual(service.shortcut(for: .speakOrStop)?.displayString, "⌥⎋")
        XCTAssertEqual(service.shortcut(for: .pauseOrResume)?.displayString, "⌥⇧⎋")
    }

    func testSavedAndClearedShortcutsAreRead() throws {
        let defaults = isolatedDefaults()
        let custom = HotKeyShortcut(keyCode: 0x31, carbonModifiers: 0x0100 | 0x0800) // ⌘⌥Space
        defaults.set(try JSONEncoder().encode(custom), forKey: GlobalHotKeyAction.speakOrStop.defaultsKey)
        defaults.set(Data(), forKey: GlobalHotKeyAction.pauseOrResume.defaultsKey)
        let service = GlobalHotKeyService(defaults: defaults)

        XCTAssertEqual(service.shortcut(for: .speakOrStop), custom)
        XCTAssertEqual(service.shortcut(for: .speakOrStop)?.displayString, "⌥⌘Space")
        XCTAssertNil(service.shortcut(for: .pauseOrResume), "an empty value means the user turned it off")
    }

    func testRecorderRejectsKeysWithoutCommandOptionOrControl() throws {
        func keyDown(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
            ))
        }
        XCTAssertNil(HotKeyShortcut(event: try keyDown([])))
        XCTAssertNil(HotKeyShortcut(event: try keyDown(.shift)))
        XCTAssertEqual(HotKeyShortcut(event: try keyDown([.control, .shift]))?.carbonModifiers, 0x1000 | 0x0200)
    }

    func testSpeakHotKeyStopsWhatIsPlaying() async {
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        store.playback = PlaybackSnapshot(
            state: .playing, activeJobID: UUID(), activeLogEntryID: nil, currentSegmentID: nil,
            elapsedTime: 1, duration: 5, bufferedDuration: 5, statusMessage: nil
        )

        let outcome = await model.handleSpeakHotKey()

        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(store.playbackState.state, .idle)
    }


    // MARK: X8 voice blends

    func testKokoroBlendVoiceIDAndDetail() {
        let blend = KokoroBlend(name: "Warm", parts: [.init(voice: "af_bella", weight: 0.6), .init(voice: "am_michael", weight: 0.4)])
        XCTAssertEqual(blend.voiceID, "af_bella*0.60,am_michael*0.40")
        XCTAssertTrue(KokoroBlend.isBlend(blend.voiceID))
        XCTAssertFalse(KokoroBlend.isBlend("af_bella"))
        XCTAssertTrue(blend.detail.contains("60%"), blend.detail)
        XCTAssertTrue(blend.detail.contains("40%"), blend.detail)
    }

    func testKokoroBlendSavesAndLoads() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "blend-\(UUID().uuidString)"))
        let blend = KokoroBlend(name: "Mix", parts: [.init(voice: "af_heart", weight: 1), .init(voice: "bf_emma", weight: 1)])
        KokoroBlend.save([blend], to: defaults)
        XCTAssertEqual(KokoroBlend.load(from: defaults), [blend])
    }

    func testAddingABlendListsAndSelectsItAndRemovingDropsIt() {
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        model.selectedVoice = "af_bella"
        model.addKokoroBlend(name: "  ", parts: [.init(voice: "af_bella", weight: 0.7), .init(voice: "am_michael", weight: 0.3), .init(voice: "bf_emma", weight: 0)])

        let blend = try! XCTUnwrap(store.kokoroBlends.first)
        XCTAssertEqual(blend.name, "My blend")
        XCTAssertEqual(blend.parts.count, 2, "zero-weight voices are left out")
        XCTAssertEqual(model.selectedVoice, blend.voiceID)
        let option = store.voiceOptions.first { $0.id == blend.voiceID }
        XCTAssertEqual(option?.source, .kokoro)
        XCTAssertEqual(option?.name, "My blend")
        XCTAssertFalse(store.voiceOptions.first { $0.id == blend.voiceID }?.isLocal ?? true, "a blend runs on the Kokoro engine")

        model.removeKokoroBlend(blend)
        XCTAssertTrue(store.kokoroBlends.isEmpty)
        XCTAssertFalse(store.voiceOptions.contains { $0.id == blend.voiceID })
        XCTAssertEqual(model.selectedVoice, "af_bella")
    }

    func testABlendNeedsTwoVoices() {
        let store = AppStore()
        let model = AppModel(store: store, dependencies: .test(engineSupervisor: FakeEngineSupervisor()))
        model.addKokoroBlend(name: "Solo", parts: [.init(voice: "af_bella", weight: 1), .init(voice: "am_michael", weight: 0)])
        XCTAssertTrue(store.kokoroBlends.isEmpty)
    }
}

/// Serves `body` for any request, for web page import tests.
private final class StubWebProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
