import Foundation

/// A single lyrics fetch can serve Now Playing and a prefetch subscriber. A
/// provider's throttle applies to the provider, including its mirrors.
actor LyricsRequestGate {
    enum Rejection: Error {
        case cooled(Date)
        case limited(String?)
        case serverBusy(String?)
        case unavailableUntil(Date)
    }

    private struct Cooldown {
        var until: Date
        var strikes: Int
        var rateLimited: Bool
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
            if let active = cooling[source], active.until > Date() {
                throw active.rateLimited ? Rejection.cooled(active.until) : Rejection.unavailableUntil(active.until)
            }
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
            switch error {
            case .limited(let header):
                result = .failure(applyCooldown(source: key.source, retryAfter: header, rateLimited: true))
            case .serverBusy(let header):
                result = .failure(applyCooldown(source: key.source, retryAfter: header, rateLimited: false))
            default: break
            }
        case .success:
            if let status = cooling[key.source], status.until <= Date() { cooling[key.source] = nil }
        default: break
        }
        for continuation in flight.listeners.values { continuation.resume(with: result) }
    }

    private func applyCooldown(source: String, retryAfter: String?, rateLimited: Bool) -> Rejection {
        let now = Date()
        let past = cooling[source]
        let stillRateLimited = past.map { $0.rateLimited && $0.until > now } ?? false
        let strikes = min(5, (past?.strikes ?? 0) + 1)
        let minimum = rateLimited ? 30.0 : 6.0
        let delay = Self.retryDelay(retryAfter, now: now) ?? (pow(2, Double(strikes - 1)) * minimum + Double.random(in: 0...3))
        let until = max(now.addingTimeInterval(delay), past?.until ?? now)
        if cooling.count >= 128 {
            let expired = cooling.filter { $0.value.until <= now }.keys
            for key in expired { cooling[key] = nil }
        }
        let limited = rateLimited || stillRateLimited
        cooling[source] = Cooldown(until: until, strikes: strikes, rateLimited: limited)
        return limited ? .cooled(until) : .unavailableUntil(until)
    }

    static func retryDelay(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(input), seconds.isFinite, seconds >= 0 { return min(31_536_000, max(1, seconds)) }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: input) else { return nil }
        return max(1, date.timeIntervalSince(now))
    }
}
