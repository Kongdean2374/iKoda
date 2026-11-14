import Foundation

/// A source row's reading position, captured before translated text changes layout.
/// Restoring an absolute offset also works when the scroll view already compensated
/// for a content-size change: the same correction is not added a second time.
public struct LyricScrollAnchor: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var id: Int
        public var minY: Double
        public var maxY: Double
        public init(id: Int, minY: Double, maxY: Double) {
            self.id = id
            self.minY = minY
            self.maxY = maxY
        }
    }

    public let source: String
    public let rowID: Int
    public let viewportY: Double

    public init?(source: String, rows: [Row], offset: Double, viewportHeight: Double,
                 preferredRowID: Int? = nil) {
        guard offset.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        let visible = rows.filter {
            $0.minY.isFinite && $0.maxY.isFinite && $0.maxY >= $0.minY
                && $0.maxY > offset && $0.minY < offset + viewportHeight
        }.sorted { $0.minY < $1.minY }
        let readingY = offset + viewportHeight * 0.32
        guard let row = visible.first(where: { $0.id == preferredRowID })
                ?? visible.last(where: { $0.minY <= readingY }) ?? visible.first else { return nil }
        self.source = source
        rowID = row.id
        viewportY = row.minY - offset
    }

    /// Returns nil when no correction is needed, the source changed, or its anchor
    /// disappeared. Insets describe the raw ScrollGeometry.contentOffset coordinate.
    public func restoredOffset(source: String, rows: [Row], currentOffset: Double,
                               contentHeight: Double, viewportHeight: Double,
                               topInset: Double = 0, bottomInset: Double = 0) -> Double? {
        guard source == self.source, currentOffset.isFinite, contentHeight.isFinite,
              viewportHeight.isFinite, viewportHeight > 0, topInset.isFinite, bottomInset.isFinite,
              let row = rows.first(where: { $0.id == rowID }), row.minY.isFinite else { return nil }
        let minimum = -max(0, topInset)
        let maximum = max(minimum, contentHeight - viewportHeight + max(0, bottomInset))
        let desired = min(maximum, max(minimum, row.minY - viewportY))
        return abs(desired - currentOffset) > 0.5 ? desired : nil
    }
}
