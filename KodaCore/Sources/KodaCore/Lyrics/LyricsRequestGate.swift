import Foundation

/// A single lyrics fetch can serve Now Playing and a prefetch subscriber. A
/// provider's throttle applies to the provider, including its mirrors.
actor LyricsRequestGate {
    enum Rejection: Error {
        case cooled(Date)
        case limited(String?)
    }

    private struct Cooldown {
        var until: Date
        var strikes: Int
    }

    private struct Key: Hashable, Sendable {
        let source: String
        let url: URL
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var listeners: [UUID: CheckedContinuation<Data, any Error>]
    }

    private var flights: [Key: Flight] = [:]
    private var cooling: [String: Cooldown] = [:]

    func fetch(source: String, url: URL, perform: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let key = Key(source: source, url: url)
        let listener = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let active = cooling[source], active.until > Date() { throw Rejection.cooled(active.until) }
            return try await withCheckedThrowingContinuation { continuation in
                if flights[key] != nil {
                    flights[key]?.listeners[listener] = continuation
                    return
                }
                let ticket = UUID()
                let task = Task {
                    let answer: Result<Data, any Error>
                    do { answer = .success(try await perform()) }
                    catch { answer = .failure(error) }
                    finish(answer, key: key, ticket: ticket)
                }
                flights[key] = Flight(id: ticket, task: task, listeners: [listener: continuation])
            }
        } onCancel: {
            Task { await self.cancel(listener, key: key) }
        }
    }

    private func cancel(_ listener: UUID, key: Key) {
        guard var flight = flights[key], let continuation = flight.listeners.removeValue(forKey: listener) else { return }
        continuation.resume(throwing: CancellationError())
        if flight.listeners.isEmpty {
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
    }

    private func finish(_ result: Result<Data, any Error>, key: Key, ticket: UUID) {
        guard let flight = flights[key], flight.id == ticket else { return }
        flights[key] = nil
        var result = result
        switch result {
        case .failure(let error as Rejection):
            guard case .limited(let header) = error else {
                for continuation in flight.listeners.values { continuation.resume(with: result) }
                return
            }
            let now = Date()
            let past = cooling[key.source]
            let strikes = min(5, (past?.strikes ?? 0) + 1)
            let delay = Self.retryDelay(header, now: now) ?? (pow(2, Double(strikes - 1)) * 30 + Double.random(in: 0...5))
            let until = max(now.addingTimeInterval(delay), past?.until ?? now)
            if cooling.count >= 128 {
                let oldest = cooling.min { $0.value.until < $1.value.until }?.key
                if let oldest, (cooling[oldest]?.until ?? now) <= now { cooling[oldest] = nil }
            }
            cooling[key.source] = Cooldown(until: until, strikes: strikes)
            result = .failure(Rejection.cooled(until))
        case .success:
            if let status = cooling[key.source], status.until <= Date() { cooling[key.source] = nil }
        default: break
        }
        for continuation in flight.listeners.values { continuation.resume(with: result) }
    }

    static func retryDelay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(input), seconds.isFinite, seconds >= 0 { return max(1, seconds) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: input) else { return nil }
        return max(1, date.timeIntervalSince(now))
    }
}
