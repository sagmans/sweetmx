# Performance

SweetMX must open and answer each keystroke at once, and cost almost nothing
while it waits in the menu bar. This document explains how the project measures
that and how the measurements stop a regression before a push.

Animations are not measured. Their cost is set by SwiftUI and the frame rate.

## Tools

| Command                   | What it does                                                                         | When                                  |
| ------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------- |
| `make benchmark`          | Runs the performance gate against `benchmarks/baseline.json`. Fails on a regression. | Each push (pre-push hook), or by hand |
| `make benchmark-baseline` | Records new limits from this Mac into `benchmarks/baseline.json`.                    | Only after an intended change         |
| `make profile-app`        | Reads CPU, wakeups, memory, disk I/O and disk space of the running app.              | To check a build in daily use         |
| `make profile-trace`      | Records a Time Profiler trace of the running app into `.build/profiles/`.            | To find where time goes               |

## The performance gate

`make benchmark` builds the app with optimizations, as it ships, and runs the
`SweetMXBenchmarks` test target. The target measures fixed inputs that are
larger than a typical Mac has: 600 apps and a full clipboard history (50 clips,
5 of them 64 KiB). It never reads your apps, your clipboard or your history.
Fixture apps are written to a temporary folder and removed after the run.

| Metric                       | Unit | What it measures                                                    |
| ---------------------------- | ---- | ------------------------------------------------------------------- |
| `app_index_scan_ms`          | ms   | Full rescan of 600 app bundles on disk                              |
| `app_index_retained_kib`     | KiB  | Heap held by the app index loaded from its cache                    |
| `app_search_typing_ms`       | ms   | Typing four queries (39 keystrokes): search and rows per keystroke  |
| `app_empty_query_rows_ms`    | ms   | Alphabetical rows with recents first, on panel show                 |
| `history_save_ms`            | ms   | Encode and write a full history                                     |
| `history_load_ms`            | ms   | Read, decode and restore a full history                             |
| `history_archive_kib`        | KiB  | Size of the history file on disk                                    |
| `clip_search_typing_ms`      | ms   | Typing three queries (30 keystrokes): search and rows per keystroke |
| `clip_search_cold_ms`        | ms   | First clipboard search, which folds every clip                      |
| `clip_search_retained_kib`   | KiB  | Heap held by the search cache after one search                      |
| `startup_services_ms`        | ms   | Index cache, history load and first rows, as at launch              |
| `idle_clipboard_polls_per_s` | 1/s  | Clipboard checks per second with the panel hidden                   |
| `idle_cpu_ms_per_s`          | ms/s | Process CPU per second while idle                                   |
| `app_binary_kib`             | KiB  | Size of the release executable                                      |
| `wm_reduce_layout_ms`        | ms   | One window manager step with 100 windows: `reduce`, then `layout`   |

Each time metric is the median of 15 runs after 3 warm-up runs (7 and 1 for
the slow scan and startup). The median ignores a run that the system paused.

### How limits are set

`make benchmark-baseline` writes the measured value and a limit for each
metric. The limit leaves room for normal noise:

| Kind   | Limit                                              | Why                                                |
| ------ | -------------------------------------------------- | -------------------------------------------------- |
| Time   | 1.5 × baseline, at least baseline + 0.25 ms        | Wall time on a desktop changes with load           |
| Memory | 1.25 × baseline, at least + 128 KiB                | Heap readings move a little with the allocator     |
| Size   | 1.10 × baseline, at least + 16 KiB                 | Sizes change only with code or toolchain           |
| Rate   | Fixed design ceiling: 2.2 polls/s, 1 ms/s idle CPU | Budgets set by design: 2 polls/s, 0.1% of one core |

The full app-index scan has a fixed 200 ms budget. Recording it updates the
measured baseline and keeps that limit. The retained-index probe waits for the
scan's queued cache writes to finish before sampling the heap.

The window manager step has a fixed 1 ms budget in the same way. Its value is
the slowest of ten inputs, so one slow kind of input cannot hide behind the
others. No real window is involved.

The baseline file also records the Mac it was made on. Time limits hold only
on similar hardware. If the gate fails on another Mac, compare the hosts first.

### When the gate fails

1. Read the table that the gate prints. The failed metric shows `REGRESSION`.
2. Find the cause. Run `make benchmark` on the commit before your change to
   confirm. Use `make profile-trace` or Instruments for detail.
3. Fix the code. Do not raise a limit to make a push pass.

### When to record a new baseline

Record a new baseline only when a change moves a metric on purpose: a faster
path (to lock in the gain), or a feature that needs more work and is accepted.

```bash
make benchmark-baseline
git diff benchmarks/baseline.json
```

`METRICS=name,name` rewrites only the named metrics. Read the diff. Commit the
new baseline in the same commit as the change that
moved the numbers, and say why in the commit body.

A new metric must be added to the benchmark and to the baseline in the same
commit. The gate fails when the baseline lists a metric that the run did not
measure, so a metric cannot be dropped without notice.

## Profiling the real app

`make profile-app` samples the running SweetMX for 10 seconds
(`PROFILE_SECONDS=30` for longer). It only reads kernel counters of your own
process and sizes two folders. Example on an Apple silicon Mac, app idle:

```text
cpu               0.32 ms/s (0.032% of one core)
wakeups           2.00 /s (idle and interrupt)
threads           4
memory footprint  37.2 MiB (peak 57.0 MiB since launch)
disk read         0.0 KiB in window
disk written      0.0 KiB in window
data on disk      1276.0 KiB
app bundle        4.9 MiB
```

What to expect while idle:

- CPU under 1 ms/s, and 2 wakeups/s from the clipboard poll.
- No disk reads or writes.
- Memory footprint grows with history size and installed apps, and drops
  only when macOS reclaims memory.

`make profile-trace` attaches Instruments' Time Profiler for 30 seconds
(`TRACE_SECONDS=10` to change). Use the app during the trace. Open the result
with `open .build/profiles/<name>.trace`. The Points of Interest track shows
the intervals that `Sources/SweetMX/PerformanceSignposts.swift` defines:
startup, app scan, app search, clip search, history load and history save.
Signposts carry names only, never queries or clip text.

## Adding a benchmark

1. Add a measurement to `Tests/SweetMXBenchmarks/PerformanceGateTests.swift`.
   Use `BenchmarkFixtures` for inputs and `SandboxFileSystem` for disk access,
   so the run never touches real user data.
2. Run `make benchmark-baseline METRICS=<new_metric_name>`. It adds only that
   entry and keeps every other committed limit. Review the new entry.
3. Add the metric to the table in this document.
4. Commit the benchmark, the baseline and the document together.
