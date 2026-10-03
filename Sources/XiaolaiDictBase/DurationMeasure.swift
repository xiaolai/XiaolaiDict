/// A `Duration` as the numbers a report prints — **one spelling for every module**. The conversion
/// was written three times (an instrument, the lookup timeline, the dictionary service's log) and
/// each copy had to get the attosecond scale right on its own.
///
/// Exact here, rounded by whoever prints it: a report that wants whole milliseconds asks for them.
public extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
