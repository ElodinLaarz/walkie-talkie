/// Non-negative delta between two readings of a monotonic lifetime counter.
///
/// The native audio layer reports lifetime totals (`recvCount`,
/// `lostFrameCount`, `underrunCount`, `staleDropCount`). Differencing two
/// consecutive snapshots normally yields the count for the interval, but a
/// native-side reset — a peer re-register zeroes its counters — makes
/// [current] < [previous] and the raw subtraction negative. Clamping the low
/// end to 0 reads that reset as "no traffic this interval" instead of
/// poisoning a downstream per-second rate with a negative spike. The upper
/// bound (2^31) caps a single interval's contribution so one absurd snapshot
/// can't blow the rate up either.
///
/// Shared by [computeLinkQuality] (`link_quality_reporter.dart`) and
/// [VoiceTelemetryMonitor] (`voice_telemetry_monitor.dart`) so the
/// counter-reset convention lives in one place rather than being copy-pasted
/// per consumer.
/// Returns `num` (not `int`) because `num.clamp` is declared to return `num`;
/// every caller feeds the result straight into a `/` rate division, so the
/// wider static type is harmless and avoids a spurious `.toInt()`.
num clampCounterDelta(int current, int previous) =>
    (current - previous).clamp(0, 1 << 31);
