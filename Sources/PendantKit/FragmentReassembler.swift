import Foundation

/// Bounded, timeout-aware assembly of out-of-order BLE notifications.
public actor FragmentReassembler {
    private struct Pending: Sendable {
        let count: UInt16
        var fragments: [UInt16: Data]
        var byteCount: Int
        var lastUpdated: Date
    }

    private var pending: [UInt32: Pending] = [:]
    private let timeout: TimeInterval
    private let maximumPendingMessages: Int
    private let maximumMessageBytes: Int

    public init(
        timeout: TimeInterval = 15,
        maximumPendingMessages: Int = 16,
        maximumMessageBytes: Int = PendantWire.maximumPayloadBytes
    ) {
        self.timeout = timeout
        self.maximumPendingMessages = max(1, maximumPendingMessages)
        self.maximumMessageBytes = max(1, maximumMessageBytes)
    }

    public func receive(_ fragment: PendantFragment, now: Date = Date()) throws -> Data? {
        expire(at: now)
        guard fragment.count > 0, fragment.count <= PendantWire.maximumFragmentCount else {
            throw PendantWireError.invalidFragmentCount
        }
        guard fragment.sequence < fragment.count else {
            throw PendantWireError.fragmentSequenceOutOfRange
        }
        guard fragment.payload.count <= maximumMessageBytes else {
            throw PendantWireError.payloadTooLarge
        }

        if fragment.count == 1 { return fragment.payload }

        if pending[fragment.index] == nil {
            if pending.count >= maximumPendingMessages {
                evictOldest()
            }
            pending[fragment.index] = Pending(
                count: fragment.count,
                fragments: [:],
                byteCount: 0,
                lastUpdated: now
            )
        }

        guard var message = pending[fragment.index] else { return nil }
        guard message.count == fragment.count else {
            pending.removeValue(forKey: fragment.index)
            throw PendantWireError.inconsistentFragmentCount
        }
        if let existing = message.fragments[fragment.sequence] {
            guard existing == fragment.payload else {
                pending.removeValue(forKey: fragment.index)
                throw PendantWireError.conflictingFragment
            }
            message.lastUpdated = now
            pending[fragment.index] = message
            return nil
        }

        guard message.byteCount <= maximumMessageBytes - fragment.payload.count else {
            pending.removeValue(forKey: fragment.index)
            throw PendantWireError.payloadTooLarge
        }
        message.fragments[fragment.sequence] = fragment.payload
        message.byteCount += fragment.payload.count
        message.lastUpdated = now
        pending[fragment.index] = message

        guard message.fragments.count == Int(message.count) else { return nil }
        var assembled = Data()
        assembled.reserveCapacity(message.byteCount)
        for sequence in 0..<message.count {
            guard let bytes = message.fragments[sequence] else { return nil }
            assembled.append(bytes)
        }
        pending.removeValue(forKey: fragment.index)
        return assembled
    }

    public func expire(at now: Date = Date()) {
        pending = pending.filter { now.timeIntervalSince($0.value.lastUpdated) < timeout }
    }

    public func reset() {
        pending.removeAll(keepingCapacity: false)
    }

    public var pendingMessageCount: Int { pending.count }

    private func evictOldest() {
        guard let oldest = pending.min(by: { $0.value.lastUpdated < $1.value.lastUpdated }) else { return }
        pending.removeValue(forKey: oldest.key)
    }
}
