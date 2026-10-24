import Foundation

func shortDate(_ ms: Int64, now: Date = Date()) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: Double(ms) / 1000)
    let cal = Calendar.current
    if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
    if cal.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(date: .numeric, time: .omitted)
}

func longDate(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    return Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
}
