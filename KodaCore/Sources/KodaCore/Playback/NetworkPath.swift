import Foundation
import Network
import os

/// Only transport metadata: never an address, network name, carrier or account identifier.
public struct NetworkSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case unknown, online, offline }
    public enum Interface: String, Codable, Sendable { case unknown, wifi, cellular, wired, other }
    public var status: Status
    public var interface: Interface
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(status: Status = .unknown, interface: Interface = .unknown,
                isExpensive: Bool = false, isConstrained: Bool = false) {
        self.status = status
        self.interface = interface
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

/// One shared monitor for quality selection and recovery. Subscribers receive the latest
/// state, never an unbounded backlog; cancellation removes their continuation.
nonisolated public final class NetworkPath: Sendable {
    public static let shared = NetworkPath()

    private struct State {
        var snapshot = NetworkSnapshot()
        var subscribers: [UUID: AsyncStream<NetworkSnapshot>.Continuation] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            let snapshot = NetworkSnapshot(
                status: path.status == .satisfied ? .online : .offline,
                interface: path.usesInterfaceType(.wifi) ? .wifi : path.usesInterfaceType(.cellular) ? .cellular
                    : path.usesInterfaceType(.wiredEthernet) ? .wired : path.status == .satisfied ? .other : .unknown,
                isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            state.withLock { state in
                guard state.snapshot != snapshot else { return }
                state.snapshot = snapshot
                for continuation in state.subscribers.values { continuation.yield(snapshot) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Koda.NetworkPath", qos: .utility))
    }

    public var snapshot: NetworkSnapshot { state.withLock { $0.snapshot } }
    public var isExpensive: Bool { snapshot.isExpensive }
    public var isConstrained: Bool { snapshot.isConstrained }

    public func updates() -> AsyncStream<NetworkSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [state] continuation in
            continuation.onTermination = { @Sendable _ in
                state.withLock { $0.subscribers[id] = nil }
            }
            // Initial delivery and subscription are atomic relative to monitor updates.
            state.withLock {
                $0.subscribers[id] = continuation
                continuation.yield($0.snapshot)
            }
        }
    }
}
