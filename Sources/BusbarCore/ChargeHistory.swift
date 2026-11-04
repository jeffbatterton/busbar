import Foundation

/// One minute's reading from the history logger.
public struct ChargeReading: Sendable, Equatable {
    public var time: Date
    public var stateOfCharge: Double
    public var wattsIn: Int
    public var wattsOut: Int

    public init(time: Date, stateOfCharge: Double, wattsIn: Int, wattsOut: Int) {
        self.time = time
        self.stateOfCharge = stateOfCharge
        self.wattsIn = wattsIn
        self.wattsOut = wattsOut
    }

    /// Power was coming in faster than it went out.
    public var isCharging: Bool { wattsIn - wattsOut > 5 }
}

/// A point on the drawn charge line.
public struct ChargePoint: Sendable, Equatable {
    public var time: Date
    public var stateOfCharge: Double
}

/// The calendar windows the chart can show. The axis always spans the whole window,
/// so the line stops at Now and the rest stays empty.
public enum HistoryRange: String, Sendable, CaseIterable {
    /// Three hours either side of now, so the latest reading sits in the middle.
    case live
    case today, week

    public static let liveSpan: TimeInterval = 3 * 3600

    public func window(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        if self == .live { return DateInterval(start: date - Self.liveSpan, duration: 2 * Self.liveSpan) }
        var calendar = calendar
        calendar.firstWeekday = 2  // weeks run Monday to Sunday
        return calendar.dateInterval(of: self == .today ? .day : .weekOfYear, for: date)!
    }

    /// Readings are averaged into buckets this long before the line is drawn.
    public var bucket: TimeInterval {
        switch self {
        case .live: 5 * 60
        case .today: 10 * 60
        case .week: 60 * 60
        }
    }
}

/// The readings for this week, kept up to date a few at a time.
public struct ChargeHistory: Sendable, Equatable {
    /// Readings further apart than this have a gap between them (the logger missed some).
    public static let maxGap: TimeInterval = 5 * 60

    public private(set) var readings: [ChargeReading] = []

    public init(readings: [ChargeReading] = []) {
        self.readings = readings
    }

    /// Where the next fetch should start: just after the last reading, or at `start`.
    public func nextFetch(from start: Date) -> Date {
        readings.last.map { $0.time.addingTimeInterval(0.001) } ?? start
    }

    public mutating func append(_ new: [ChargeReading]) {
        let last = readings.last?.time ?? .distantPast
        readings += new.filter { $0.time > last }
    }

    public mutating func trim(before start: Date) {
        readings.removeAll { $0.time < start }
    }

    /// Splits readings into runs wherever the logger went quiet.
    public static func runs(_ readings: [ChargeReading]) -> [[ChargeReading]] {
        var runs: [[ChargeReading]] = []
        for reading in readings {
            if let last = runs.last?.last, reading.time.timeIntervalSince(last.time) <= maxGap {
                runs[runs.count - 1].append(reading)
            } else {
                runs.append([reading])
            }
        }
        return runs
    }

    /// Averages a run into buckets so minute-to-minute noise doesn't show, then ends it on
    /// its last exact reading so the line lands on the current level.
    public static func smoothed(_ run: [ChargeReading], bucket: TimeInterval) -> [ChargePoint] {
        guard let last = run.last else { return [] }
        var points: [ChargePoint] = []
        var group: [ChargeReading] = []
        func flush() {
            guard !group.isEmpty else { return }
            let mean = group.map(\.time.timeIntervalSince1970).reduce(0, +) / Double(group.count)
            points.append(ChargePoint(time: Date(timeIntervalSince1970: mean),
                                      stateOfCharge: group.map(\.stateOfCharge).reduce(0, +) / Double(group.count)))
            group = []
        }
        for reading in run {
            if let first = group.first, floor(first.time.timeIntervalSince1970 / bucket)
                != floor(reading.time.timeIntervalSince1970 / bucket) {
                flush()
            }
            group.append(reading)
        }
        flush()
        points[points.count - 1] = ChargePoint(time: last.time, stateOfCharge: last.stateOfCharge)
        return points
    }

    /// When power was coming in, ignoring brief blips: stretches under `merge` apart are
    /// joined, then any shorter than `minimum` are dropped. Never spans a gap.
    public static func chargingBands(_ readings: [ChargeReading], merge: TimeInterval = 15 * 60,
                                     minimum: TimeInterval = 10 * 60) -> [DateInterval] {
        runs(readings).flatMap { run -> [DateInterval] in
            var bands: [DateInterval] = []
            var start: Date?
            for (index, reading) in run.enumerated() {
                if reading.isCharging, start == nil { start = reading.time }
                guard let begun = start, !reading.isCharging || index == run.count - 1 else { continue }
                let end = reading.time
                if let previous = bands.last, begun.timeIntervalSince(previous.end) < merge {
                    bands[bands.count - 1] = DateInterval(start: previous.start, end: end)
                } else {
                    bands.append(DateInterval(start: begun, end: end))
                }
                start = nil
            }
            return bands.filter { $0.duration >= minimum }
        }
    }
}

public enum HistoryError: LocalizedError {
    case http(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .http(401): "The history token was refused"
        case .http(let status): "History logger returned HTTP \(status)"
        case .malformedResponse: "Unexpected response from the history logger"
        }
    }
}

/// Reads from the history logger (`logger/` in this repo).
public struct HistoryClient: Sendable {
    public var baseURL: URL
    public var token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func readings(since: Date, until: Date = .now) async throws -> [ChargeReading] {
        var components = URLComponents(url: baseURL.appending(path: "readings"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "since", value: String(Int64((since.timeIntervalSince1970 * 1000).rounded(.up)))),
            URLQueryItem(name: "until", value: String(Int64((until.timeIntervalSince1970 * 1000).rounded(.up)))),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw HistoryError.http(http.statusCode) }
        return try Self.parse(data)
    }

    /// Sends the alert thresholds, in percent, for the web app to use.
    public func saveThresholds(low: Double, critical: Double) async throws {
        var request = URLRequest(url: baseURL.appending(path: "settings"), timeoutInterval: 20)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["lowThreshold": low, "criticalThreshold": critical])
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw HistoryError.http(http.statusCode) }
    }

    /// `{ "readings": [[time ms, charge %, watts in, watts out], …] }`
    static func parse(_ data: Data) throws -> [ChargeReading] {
        struct Response: Decodable { var readings: [[Double]] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw HistoryError.malformedResponse
        }
        return try response.readings.map { row in
            guard row.count >= 4 else { throw HistoryError.malformedResponse }
            return ChargeReading(time: Date(timeIntervalSince1970: row[0] / 1000), stateOfCharge: row[1],
                                 wattsIn: Int(row[2]), wattsOut: Int(row[3]))
        }
    }
}
