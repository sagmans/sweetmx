import Darwin
import Foundation

/// How a metric is read, so the gate picks a tolerance that matches its noise: wall time on a desktop
/// moves with load, heap and file sizes barely move, and a rate has a fixed design ceiling.
enum MetricKind: String, Codable {
    case time
    case memory
    case size
    case rate
}

/// One measured number. Every metric is a cost, so lower is always better and only a rise fails.
struct Measurement: Codable, Equatable {
    let name: String
    let kind: MetricKind
    let unit: String
    let value: Double
    let summary: String
    /// The design limit of a `.rate` metric, carried with the number so a rate can never be recorded
    /// without one (which would leave it zero headroom). Nil for every other kind.
    let ceiling: Double?

    init(name: String, kind: MetricKind, unit: String, value: Double, summary: String) {
        precondition(kind != .rate, "A rate needs a ceiling; use init(rate:)")
        self.name = name
        self.kind = kind
        self.unit = unit
        self.value = value
        self.summary = summary
        ceiling = nil
    }

    init(rate name: String, unit: String, value: Double, ceiling: Double, summary: String) {
        self.name = name
        kind = .rate
        self.unit = unit
        self.value = value
        self.summary = summary
        self.ceiling = ceiling
    }
}

/// The committed bar for one metric. `limit` is what fails a push; `baseline` is the value it was
/// derived from, kept so a reader can see how much headroom the limit leaves.
struct BaselineEntry: Codable, Equatable {
    let kind: MetricKind
    let unit: String
    let baseline: Double
    let limit: Double
    let summary: String
}

/// `benchmarks/baseline.json`. The host is recorded because wall-time limits only hold on comparable
/// hardware; a gate failure on another Mac should be read against it before anything else.
struct BaselineFile: Codable {
    let host: String
    let recordedAt: String
    let metrics: [String: BaselineEntry]

    /// Sorted keys and indentation, so the committed file diffs line by line between recordings.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Measurement primitives. All of them read process-wide counters, so benchmarks run one at a time
/// on the main actor and never overlap.
enum Probe {
    /// Untimed passes before sampling, so first-touch costs (page faults, lazy caches, dyld binding)
    /// do not land in the samples. The app pays those once per launch, not per keystroke.
    static let warmupPasses = 3
    /// Odd, so the median is one real sample. Enough that one preempted pass cannot move the median.
    static let samplePasses = 15
    static let bytesPerKibibyte = 1024.0

    private static let millisecondsPerSecond = 1000.0
    private static let microsecondsPerMillisecond = 1000.0
    private static let attosecondsPerMillisecond = 1e15

    /// Median wall time of `work` in milliseconds. Wall time, not CPU time, because the user waits on
    /// wall time; the median rejects a preempted pass that a mean would absorb. A throw ends the
    /// measurement at once, so a failing pass never counts as a fast one.
    static func medianMilliseconds(warmup: Int = warmupPasses, samples: Int = samplePasses, _ work: () throws -> Void) rethrows -> Double {
        for _ in 0 ..< warmup {
            try work()
        }
        let clock = ContinuousClock()
        var durations: [Double] = []
        durations.reserveCapacity(samples)
        for _ in 0 ..< samples {
            let start = clock.now
            try autoreleasepool { try work() }
            let parts = (clock.now - start).components
            durations.append(Double(parts.seconds) * millisecondsPerSecond + Double(parts.attoseconds) / attosecondsPerMillisecond)
        }
        durations.sort()
        return durations[durations.count / 2]
    }

    /// Bytes of malloc heap in use across all zones. Retained structures (indexes, fold caches, loaded
    /// history) are what keeps the app's resident memory up between uses, so this is the RAM metric.
    static func heapBytesInUse() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use)
    }

    /// Heap growth that outlives `build`, in KiB. The result is kept alive until the second reading,
    /// so the delta is what the structure costs to hold, not what was allocated and freed on the way.
    static func retainedKibibytes<T>(_ build: () -> T) -> (value: T, kibibytes: Double) {
        let before = autoreleasepool { heapBytesInUse() }
        let value = autoreleasepool { build() }
        let after = autoreleasepool { heapBytesInUse() }
        return (value, max(0, after - before) / bytesPerKibibyte)
    }

    /// User plus system CPU time of this process in milliseconds, for idle-cost readings.
    static func processCPUMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func milliseconds(_ time: timeval) -> Double {
            Double(time.tv_sec) * millisecondsPerSecond + Double(time.tv_usec) / microsecondsPerMillisecond
        }
        return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
    }

    /// Size of a file in KiB, or nil when it is missing, so a gate never compares against zero.
    static func fileKibibytes(at url: URL) -> Double? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Double(size) / bytesPerKibibyte
    }
}

/// The Mac a run happened on: model identifier (such as Mac15,8) and core count. Enough to tell two
/// benchmark hosts apart without recording anything that identifies the person.
enum BenchmarkHost {
    private static let modelKey = "hw.model"
    private static let unknownModel = "unknown Mac"

    static func describe() -> String {
        var size = 0
        var model: [UInt8] = []
        if sysctlbyname(modelKey, nil, &size, nil, 0) == 0, size > 0 {
            model = [UInt8](repeating: 0, count: size)
            if sysctlbyname(modelKey, &model, &size, nil, 0) != 0 {
                model = []
            }
        }
        let modelName = String(bytes: model.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        return "\(modelName.isEmpty ? unknownModel : modelName), \(ProcessInfo.processInfo.activeProcessorCount) cores"
    }
}

/// Applies the committed limits and records new ones. Kept apart from the benchmarks so the policy
/// (how much slower is a regression) has one owner.
enum PerformanceGate {
    /// The full scan has a fixed latency budget, including after a baseline recording.
    static let appIndexScan = (name: "app_index_scan_ms", limitMilliseconds: 200.0)
    /// One step of the window manager model must cost far less than moving one real window, so
    /// the model is never what the user waits for. The budget is fixed by the window manager plan.
    static let windowManagerStep = (name: "wm_reduce_layout_ms", limitMilliseconds: 1.0)
    /// Metrics whose limit is a design budget, not a factor of what one recording measured.
    private static let fixedTimeBudgets = [appIndexScan, windowManagerStep]

    /// Wall time on a shared desktop varies by tens of percent run to run; 1.5x stays clear of that
    /// noise while still catching an accidental quadratic path or a lost cache.
    private static let timeFactor = 1.5
    /// Absolute floor for sub-millisecond metrics, where scheduler jitter alone exceeds 50%.
    private static let timeSlackMilliseconds = 0.25
    /// Heap readings move only with allocator rounding and background framework work.
    private static let memoryFactor = 1.25
    private static let memorySlackKibibytes = 128.0
    /// Binary and archive sizes are deterministic for a given toolchain; 10% leaves room for a
    /// compiler update while flagging a new dependency or an unbounded format change.
    private static let sizeFactor = 1.10
    private static let sizeSlackKibibytes = 16.0
    /// Limits are stored to three decimals so the committed file stays readable and diffs stay small.
    private static let roundingScale = 1000.0
    /// Column widths of the report table; the name column fits the longest metric name.
    private static let nameColumnWidth = 36
    private static let numberColumnWidth = 13

    enum Outcome: Equatable {
        case pass
        case regression
        case missingBaseline
    }

    /// Which metrics a recording rewrites: all of them, or only the named ones, so adding one metric
    /// does not quietly move the limits of all the others to this run's noise.
    enum RecordScope: Equatable {
        case all
        case only(Set<String>)
    }

    static func limit(for measurement: Measurement) -> Double {
        if let budget = fixedTimeBudgets.first(where: { $0.name == measurement.name }) {
            return budget.limitMilliseconds
        }
        let value = measurement.value
        let raw: Double = switch measurement.kind {
        case .time: max(value * timeFactor, value + timeSlackMilliseconds)
        case .memory: max(value * memoryFactor, value + memorySlackKibibytes)
        case .size: max(value * sizeFactor, value + sizeSlackKibibytes)
        // Guaranteed by `Measurement.init(rate:)`; the fallback only satisfies the optional.
        case .rate: measurement.ceiling ?? value
        }
        return (raw * roundingScale).rounded(.up) / roundingScale
    }

    static func evaluate(_ measurement: Measurement, against baseline: BaselineFile) -> Outcome {
        guard let entry = baseline.metrics[measurement.name] else { return .missingBaseline }
        return measurement.value <= entry.limit ? .pass : .regression
    }

    /// The baseline after recording `measurements` in `scope` on top of `existing`. Entries outside
    /// the scope keep their committed values.
    static func record(_ measurements: [Measurement], scope: RecordScope, over existing: BaselineFile?, host: String) -> BaselineFile {
        var metrics = existing?.metrics ?? [:]
        for measurement in measurements {
            if case let .only(names) = scope, !names.contains(measurement.name) {
                continue
            }
            metrics[measurement.name] = BaselineEntry(
                kind: measurement.kind,
                unit: measurement.unit,
                baseline: (measurement.value * roundingScale).rounded() / roundingScale,
                limit: limit(for: measurement),
                summary: measurement.summary
            )
        }
        return BaselineFile(host: host, recordedAt: ISO8601DateFormatter().string(from: Date()), metrics: metrics)
    }

    /// A fixed-width table, because it is read in a terminal at the end of a push.
    static func report(_ measurements: [Measurement], baseline: BaselineFile) -> String {
        let header = "metric".padding(toLength: nameColumnWidth, withPad: " ", startingAt: 0)
            + "value".padding(toLength: numberColumnWidth, withPad: " ", startingAt: 0)
            + "limit".padding(toLength: numberColumnWidth, withPad: " ", startingAt: 0)
            + "status"
        let rows = measurements.map { measurement -> String in
            let status = switch evaluate(measurement, against: baseline) {
            case .pass: "ok"
            case .regression: "REGRESSION"
            case .missingBaseline: "NO BASELINE"
            }
            let value = String(format: "%.3f %@", measurement.value, measurement.unit)
            let limit = baseline.metrics[measurement.name].map { String(format: "%.3f %@", $0.limit, $0.unit) } ?? "-"
            return measurement.name.padding(toLength: nameColumnWidth, withPad: " ", startingAt: 0)
                + value.padding(toLength: numberColumnWidth, withPad: " ", startingAt: 0)
                + limit.padding(toLength: numberColumnWidth, withPad: " ", startingAt: 0)
                + status
        }
        return ([header] + rows).joined(separator: "\n")
    }
}
