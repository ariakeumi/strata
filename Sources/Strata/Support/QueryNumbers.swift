/// `value` as Int64, clamped to its range (a typed "size:9e30" or "1e20 days" must not trap); nil for NaN.
nonisolated package func saturatingInt64(_ value: Double) -> Int64? {
    guard !value.isNaN else { return nil }
    if value >= 9.2e18 { return .max }
    if value <= -9.2e18 { return .min }
    return Int64(value)
}

/// A count of days, weeks… from a query, kept to a sane range (date arithmetic overflows on absurd values).
nonisolated package func boundedCount(_ value: Double) -> Int {
    guard value.isFinite else { return 0 }
    return Int(max(-1_000_000, min(1_000_000, value)))
}
