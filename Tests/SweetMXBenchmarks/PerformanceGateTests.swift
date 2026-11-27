@testable import SweetMX
import WMCore
import XCTest

/// The performance regression gate: measures every hot path the user waits on and every resource the
/// app holds while idle, then fails when any metric passes its committed limit.
///
/// One test runs all benchmarks in sequence, because they read process-wide counters (heap, CPU) that
/// parallel or interleaved tests would corrupt. It runs only through `make benchmark`, which builds with
/// optimizations; debug numbers say nothing about the shipped app.
@MainActor
final class PerformanceGateTests: XCTestCase {
    private enum Environment {
        /// Set by `make benchmark`; without it the test skips, so `swift test` stays a functional run.
        static let enabled = "SWEETMX_BENCHMARK"
        /// Set by `make benchmark-baseline` to rewrite the committed limits from this run: `1` for every
        /// metric, or a comma-separated list of metric names to rewrite only those.
        static let record = "SWEETMX_BENCHMARK_RECORD"
        static let recordSeparator: Character = ","
        /// Release binary whose size is gated; `make benchmark` passes the path it just built.
        static let binary = "SWEETMX_BENCHMARK_BINARY"
        /// Where this run's raw numbers go, for comparing runs or charting them.
        static let results = "SWEETMX_BENCHMARK_RESULTS"
        static let on = "1"
    }

    private enum BenchmarkError: Error {
        case indexPersistenceTimedOut
    }

    /// A stalled cache write must fail the benchmark before it samples or records process-wide heap.
    private static let persistenceTimeout: DispatchTimeInterval = .seconds(10)

    /// Typed as the launcher receives them: one search per keystroke, ending with one query that
    /// matches nothing, which is the most expensive search because every candidate is checked in full.
    private static let appQueries = ["visual studio code", "term", "spotify music", "zzqx"]
    private static let clipQueries = ["deploy server", "timeout cache", "zzqx"]
    /// Recents shown first on an empty query; the store keeps up to 50, the panel shows a handful.
    private static let recentCount = 10
    /// Long enough that two or more poll ticks land inside it even with the timers' tolerance.
    private static let idleWindowSeconds = 4.0
    /// The hidden-panel poll is designed for two reads per second; a small margin covers timer
    /// coalescing, while a third read per second (a second timer, a faster pace) fails.
    private static let idlePollCeiling = 2.2
    /// Idle CPU budget: 0.1% of one core. Measured runs sit near 0.2-0.35 ms/s, and the whole-process
    /// reading jitters by about that much, so a factor of the baseline would flake; a fixed budget
    /// still fails on a busy loop or a timer firing many times a second.
    private static let idleCPUCeiling = 1.0

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let baselineURL = packageRoot.appendingPathComponent("benchmarks/baseline.json")
    private static let defaultResultsURL = packageRoot.appendingPathComponent(".build/benchmark/results.json")
    /// Prefix of the temporary sandbox folder; tear-down removes only a folder that carries it.
    private static let sandboxPrefix = "sweetmx-benchmark-"

    private var sandbox: SandboxFileSystem!
    private var measurements: [Measurement] = []

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(ProcessInfo.processInfo.environment[Environment.enabled] == Environment.on, "Run with `make benchmark`")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(Self.sandboxPrefix + UUID().uuidString, isDirectory: true)
        sandbox = SandboxFileSystem(root: root)
        try FileManager.default.createDirectory(at: sandbox.applicationSupport, withIntermediateDirectories: true)
        try BenchmarkFixtures.writeApplications(into: sandbox.home.appendingPathComponent("Applications", isDirectory: true))
        measurements = []
    }

    override func tearDown() async throws {
        // Only the folder this test created, named with a fresh UUID, is removed.
        if let sandbox, sandbox.root.lastPathComponent.hasPrefix(Self.sandboxPrefix) {
            do {
                try FileManager.default.removeItem(at: sandbox.root)
            } catch {
                // Not a gate failure: the numbers are valid, and the OS clears temporary folders. Reported
                // so a leak across many runs is visible.
                emit("Could not remove benchmark sandbox \(sandbox.root.path): \(error)")
            }
        }
        sandbox = nil
        try await super.tearDown()
    }

    func testPerformanceStaysWithinBaseline() throws {
        try measureApplicationIndex()
        try measureApplicationSearch()
        try measureClipboardHistory()
        try measureClipboardSearch()
        try measureStartup()
        measureIdleCost()
        try measureBinarySize()
        measureWindowManagerModel()

        let environment = ProcessInfo.processInfo.environment
        try writeResults(to: environment[Environment.results].map(URL.init(fileURLWithPath:)) ?? Self.defaultResultsURL)

        if let request = environment[Environment.record] {
            try recordBaseline(request)
            return
        }

        let baseline = try JSONDecoder().decode(BaselineFile.self, from: Data(contentsOf: Self.baselineURL))
        emit("Baseline host: \(baseline.host), recorded \(baseline.recordedAt); this host: \(BenchmarkHost.describe())")
        emit(PerformanceGate.report(measurements, baseline: baseline))
        for measurement in measurements {
            let outcome = PerformanceGate.evaluate(measurement, against: baseline)
            XCTAssertEqual(outcome, .pass, "\(measurement.name) = \(measurement.value) \(measurement.unit): \(measurement.summary)")
        }
        // A metric dropped from the suite must also leave the baseline, so the gate never looks wider than it is.
        let measured = Set(measurements.map(\.name))
        XCTAssertEqual(Set(baseline.metrics.keys).subtracting(measured), [], "Baseline lists metrics this run did not measure")
    }

    // MARK: - Benchmarks

    /// Folder scan at launch and after installs. Real disk, real bundle checks.
    private func measureApplicationIndex() throws {
        let indexer = ApplicationIndexer(fileSystem: sandbox, scanSynchronously: true)
        XCTAssertEqual(indexer.allApplications.count, BenchmarkFixtures.applicationCount, "Fixture apps must all be indexed")
        add(PerformanceGate.appIndexScan.name, .time, "ms", Probe.medianMilliseconds(warmup: 1, samples: 7) { indexer.scanForApplications() },
            "Full rescan of \(BenchmarkFixtures.applicationCount) app bundles on disk")

        // Cache encoding from the timed scans also allocates on the process heap.
        guard indexer.waitForPendingPersistence(until: .now() + Self.persistenceTimeout) == .success else {
            throw BenchmarkError.indexPersistenceTimedOut
        }
        let retained = Probe.retainedKibibytes { ApplicationIndexer(fileSystem: sandbox, scanSynchronously: false) }
        XCTAssertEqual(retained.value.allApplications.count, BenchmarkFixtures.applicationCount, "Index cache must load at launch")
        add("app_index_retained_kib", .memory, "KiB", retained.kibibytes, "Heap held by the index loaded from its cache")
    }

    /// The launcher's main loop: a search and a row build per keystroke.
    private func measureApplicationSearch() throws {
        let indexer = ApplicationIndexer(fileSystem: sandbox, scanSynchronously: false)
        let service = SearchService(indexer: indexer)
        let keystrokes = Self.appQueries.flatMap(BenchmarkFixtures.keystrokes(of:))
        XCTAssertFalse(service.search("visual studio code").isEmpty, "Typed query must match fixture apps")

        let typing = Probe.medianMilliseconds {
            service.resetCache()
            for query in keystrokes {
                _ = AppRowBuilder.rows(from: service.search(query))
            }
        }
        add("app_search_typing_ms", .time, "ms", typing, "\(keystrokes.count) keystrokes over \(BenchmarkFixtures.applicationCount) apps, search and rows")

        let snapshot = service.applicationSnapshot()
        let recents = Array(snapshot.applications.prefix(Self.recentCount).map(\.bundlePath))
        let empty = Probe.medianMilliseconds {
            _ = AlphabeticalAppRows(applications: snapshot.applications, revision: snapshot.revision).ordered(recentPaths: recents)
        }
        add("app_empty_query_rows_ms", .time, "ms", empty, "Alphabetical rows with recents first, on first panel show")
    }

    /// History persistence: each copy schedules a save, and launch loads the archive.
    private func measureClipboardHistory() throws {
        let clips = BenchmarkFixtures.clips()
        let folder = sandbox.applicationSupport.appendingPathComponent(AppDataLocation.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = folder.appendingPathComponent("clipboard_history.json")
        let images = ClipboardImageStore(directory: folder.appendingPathComponent(ClipboardImageStore.directoryName, isDirectory: true), fileSystem: sandbox)

        let save = try Probe.medianMilliseconds {
            try sandbox.writePrivateFile(ClipboardHistoryArchive.encode(clips), to: archive)
        }
        add("history_save_ms", .time, "ms", save, "Encode and write \(clips.count) clips")

        var loadedCount = 0
        let load = try Probe.medianMilliseconds {
            let data = try sandbox.readPrivateFile(at: archive, maximumBytes: ClipboardHistoryLimits.archiveReadLimit) ?? Data()
            loadedCount = try ClipboardHistoryArchive.restore(ClipboardHistoryArchive.decode(data), images: images).items.count
        }
        XCTAssertEqual(loadedCount, clips.count, "Every saved clip must load back")
        add("history_load_ms", .time, "ms", load, "Read, decode and restore \(clips.count) clips")

        let size = try XCTUnwrap(Probe.fileKibibytes(at: archive), "Archive must exist after a save")
        add("history_archive_kib", .size, "KiB", size, "On-disk archive for a full history")
    }

    /// Clipboard mode's per-keystroke cost, warm (fold cache filled) and cold (first search after launch).
    private func measureClipboardSearch() throws {
        let clips = BenchmarkFixtures.clips()
        let keystrokes = Self.clipQueries.flatMap(BenchmarkFixtures.keystrokes(of:))
        let kinds = ClipKindCache()
        let warmIndex = ClipSearchIndex()
        XCTAssertFalse(warmIndex.search("deploy", in: clips) { false }.isEmpty, "Typed query must match fixture clips")

        let typing = Probe.medianMilliseconds {
            for query in keystrokes {
                let matches = warmIndex.search(query, in: clips) { false }
                _ = ClipRowBuilder.rows(for: matches, query: query, kinds: kinds)
            }
        }
        add("clip_search_typing_ms", .time, "ms", typing, "\(keystrokes.count) keystrokes over \(clips.count) clips, search and rows")

        let cold = Probe.medianMilliseconds { _ = ClipSearchIndex().search("deploy", in: clips) { false } }
        add("clip_search_cold_ms", .time, "ms", cold, "First search: folds every clip, including large ones")

        let retained = Probe.retainedKibibytes { () -> ClipSearchIndex in
            let index = ClipSearchIndex()
            _ = index.search("deploy", in: clips) { false }
            return index
        }
        add("clip_search_retained_kib", .memory, "KiB", retained.kibibytes, "Fold cache held after one search of a full history")
    }

    /// Service setup before the first panel can show: index cache, history load, first rows.
    private func measureStartup() throws {
        let pasteboard = CountingPasteboard()
        let startup = Probe.medianMilliseconds(warmup: 1, samples: 7) {
            let indexer = ApplicationIndexer(fileSystem: sandbox, scanSynchronously: false)
            let service = SearchService(indexer: indexer)
            let manager = ClipboardManager(pasteboard: pasteboard, fileSystem: sandbox, loadSynchronously: true, frontmostBundleID: { nil }, ownBundleID: nil)
            let snapshot = service.applicationSnapshot()
            _ = AlphabeticalAppRows(applications: snapshot.applications, revision: snapshot.revision).ordered(recentPaths: [])
            _ = manager.getHistory()
        }
        add("startup_services_ms", .time, "ms", startup, "Index cache, history load and first app rows, as at launch")
    }

    /// What the app costs while nobody uses it, which is nearly all day.
    private func measureIdleCost() {
        let pasteboard = CountingPasteboard()
        let manager = ClipboardManager(pasteboard: pasteboard, fileSystem: sandbox, loadSynchronously: true, frontmostBundleID: { nil }, ownBundleID: nil)
        let readsAtStart = pasteboard.changeCountReads
        let cpuAtStart = Probe.processCPUMilliseconds()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: Self.idleWindowSeconds))
        let cpu = Probe.processCPUMilliseconds() - cpuAtStart
        let polls = Double(pasteboard.changeCountReads - readsAtStart)
        withExtendedLifetime(manager) {}
        addRate("idle_clipboard_polls_per_s", "1/s", polls / Self.idleWindowSeconds, ceiling: Self.idlePollCeiling, "Clipboard checks per second with the panel hidden")
        addRate("idle_cpu_ms_per_s", "ms/s", cpu / Self.idleWindowSeconds, ceiling: Self.idleCPUCeiling, "Process CPU per second of idle, with monitoring on")
    }

    /// Disk and launch cost of the shipped executable.
    private func measureBinarySize() throws {
        guard let path = ProcessInfo.processInfo.environment[Environment.binary] else {
            XCTFail("\(Environment.binary) is not set; run through `make benchmark`")
            return
        }
        let size = try XCTUnwrap(Probe.fileKibibytes(at: URL(fileURLWithPath: path)), "Release binary missing at \(path)")
        add("app_binary_kib", .size, "KiB", size, "Release executable size")
    }

    // MARK: - Output

    /// Writes the baseline for the metrics `request` names, keeping every other committed entry.
    private func recordBaseline(_ request: String) throws {
        let measured = Set(measurements.map(\.name))
        let scope: PerformanceGate.RecordScope
        if request == Environment.on {
            scope = .all
        } else {
            let names = Set(request.split(separator: Environment.recordSeparator).map { $0.trimmingCharacters(in: .whitespaces) })
            let unknown = names.subtracting(measured)
            guard unknown.isEmpty else {
                XCTFail("Cannot record unknown metrics: \(unknown.sorted().joined(separator: ", "))")
                return
            }
            scope = .only(names)
        }
        let existing = try? JSONDecoder().decode(BaselineFile.self, from: Data(contentsOf: Self.baselineURL))
        if scope != .all, existing == nil {
            XCTFail("No readable baseline to merge into; record every metric with SWEETMX_BENCHMARK_RECORD=1")
            return
        }
        let file = PerformanceGate.record(measurements, scope: scope, over: existing, host: BenchmarkHost.describe())
        try BaselineFile.encoder().encode(file).write(to: Self.baselineURL, options: .atomic)
        emit("Recorded \(scope == .all ? "all" : "selected") metrics to benchmarks/baseline.json on \(file.host)")
        emit(PerformanceGate.report(measurements, baseline: file))
    }

    /// One step of the window manager: an input through `reduce`, then the frames of the result.
    /// The metric is the slowest of several inputs, so no kind of input can hide behind a fast one.
    private func measureWindowManagerModel() {
        let state = BenchmarkFixtures.windowManagerState()
        XCTAssertEqual(Presentation(of: state).frames.count, BenchmarkFixtures.windowManagerWindowCount, "Every fixture window must be on screen")
        let slowest = BenchmarkFixtures.windowManagerInputs.map { input in
            Probe.medianMilliseconds {
                let next = reduce(state, input).state
                _ = layout(next.grid.currentWorkspace, screenRect: next.screen, gaps: next.gaps)
            }
        }.max() ?? .infinity
        add(PerformanceGate.windowManagerStep.name, .time, "ms", slowest,
            "Slowest of \(BenchmarkFixtures.windowManagerInputs.count) inputs: reduce plus layout, \(BenchmarkFixtures.windowManagerWindowCount) windows")
    }

    private func add(_ name: String, _ kind: MetricKind, _ unit: String, _ value: Double, _ summary: String) {
        measurements.append(Measurement(name: name, kind: kind, unit: unit, value: value, summary: summary))
    }

    private func addRate(_ name: String, _ unit: String, _ value: Double, ceiling: Double, _ summary: String) {
        measurements.append(Measurement(rate: name, unit: unit, value: value, ceiling: ceiling, summary: summary))
    }

    private func writeResults(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BaselineFile.encoder().encode(measurements).write(to: url, options: .atomic)
    }

    /// Standard error, so the table shows in the make output next to XCTest's own lines.
    private func emit(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
