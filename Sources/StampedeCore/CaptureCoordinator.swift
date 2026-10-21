import Foundation

/// Observation ordering and lifecycle invalidation are independent of image processing speed.
public struct CaptureCoordinator: Sendable {
    public struct Ticket: Sendable {
        let epoch: UInt64
        let sequence: UInt64
        public let time: Date
        let bytes: Int
    }
    private var epoch: UInt64 = 0
    private var sequence: UInt64 = 0
    private var time = Date.distantPast
    private var pendingBytes = 0
    public init() {}
    public mutating func observe(now: Date = Date()) -> Date {
        sequence += 1
        time = max(now, time.addingTimeInterval(0.000001))
        return time
    }
    public mutating func reserve(bytes: Int, now: Date = Date()) -> Ticket? {
        let capturedAt = observe(now: now)
        guard bytes > 0, bytes <= ClipboardImage.maximumBytes - pendingBytes else { return nil }
        pendingBytes += bytes
        return Ticket(epoch: epoch, sequence: sequence, time: capturedAt, bytes: bytes)
    }
    public func accepts(_ ticket: Ticket, capacity: Int) -> Bool {
        ticket.epoch == epoch && sequence - ticket.sequence < UInt64(capacity)
    }
    public mutating func finish(_ ticket: Ticket) { pendingBytes -= ticket.bytes }
    public mutating func invalidate() { epoch += 1 }
}
