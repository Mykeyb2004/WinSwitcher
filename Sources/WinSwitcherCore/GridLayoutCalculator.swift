import CoreGraphics
import Foundation

public struct SwitcherGridMetrics: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cardWidth: CGFloat
    public let cardHeight: CGFloat
    public let cardSpacing: CGFloat
    public let horizontalPadding: CGFloat
    public let verticalPadding: CGFloat
    public let footerHeight: CGFloat
    public let panelWidth: CGFloat
    public let panelHeight: CGFloat
    public let needsScroll: Bool

    public init(
        columns: Int,
        rows: Int,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        cardSpacing: CGFloat,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        footerHeight: CGFloat,
        panelWidth: CGFloat,
        panelHeight: CGFloat,
        needsScroll: Bool
    ) {
        self.columns = columns
        self.rows = rows
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardSpacing = cardSpacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.footerHeight = footerHeight
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        self.needsScroll = needsScroll
    }
}

public enum GridLayoutCalculator {
    /// Computes Windows 11 style adaptive card grid metrics for a given item count and screen frame.
    public static func compute(itemCount: Int, screenSize: CGSize) -> SwitcherGridMetrics {
        let safeCount = max(1, itemCount)
        let cardSpacing: CGFloat = 14
        let horizontalPadding: CGFloat = 22
        let verticalPadding: CGFloat = 20
        let footerHeight: CGFloat = 34

        let maxPanelWidth = min(max(screenSize.width * 0.82, 520), 1440)
        let maxPanelHeight = min(max(screenSize.height * 0.72, 260), 860)

        // Pick comfortable Windows 11 card size depending on item count
        let preferredCardWidth: CGFloat
        let preferredCardHeight: CGFloat
        if safeCount <= 5 {
            preferredCardWidth = 236
            preferredCardHeight = 172
        } else if safeCount <= 12 {
            preferredCardWidth = 216
            preferredCardHeight = 158
        } else {
            preferredCardWidth = 196
            preferredCardHeight = 144
        }

        let maxColsThatFit = max(
            1,
            Int(floor((maxPanelWidth - horizontalPadding * 2 + cardSpacing) / (preferredCardWidth + cardSpacing)))
        )

        // Balance rows nicely (like Windows 11: e.g. 6 items -> 3x2 or 6x1 if wide enough; cap single row at 5-6)
        let columns: Int
        if safeCount <= min(5, maxColsThatFit) {
            columns = safeCount
        } else if safeCount == 6 && maxColsThatFit >= 6 {
            columns = 6
        } else {
            columns = min(maxColsThatFit, min(safeCount, 6))
        }

        let rows = Int(ceil(Double(safeCount) / Double(columns)))

        let contentWidth = CGFloat(columns) * preferredCardWidth + CGFloat(max(0, columns - 1)) * cardSpacing
        let rawPanelWidth = contentWidth + horizontalPadding * 2
        let panelWidth = min(rawPanelWidth, maxPanelWidth)

        let gridHeight = CGFloat(rows) * preferredCardHeight + CGFloat(max(0, rows - 1)) * cardSpacing
        let rawPanelHeight = gridHeight + verticalPadding * 2 + footerHeight
        let needsScroll = rawPanelHeight > maxPanelHeight
        let panelHeight = min(rawPanelHeight, maxPanelHeight)

        return SwitcherGridMetrics(
            columns: columns,
            rows: rows,
            cardWidth: preferredCardWidth,
            cardHeight: preferredCardHeight,
            cardSpacing: cardSpacing,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            footerHeight: footerHeight,
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            needsScroll: needsScroll
        )
    }

    /// 2D arrow-key navigation matching Windows 11 Alt+Tab grid wrapping rules.
    public static func nextIndex(
        current: Int,
        count: Int,
        columns: Int,
        direction: GridDirection
    ) -> Int {
        guard count > 1 else { return 0 }
        let cols = max(1, columns)
        let clamped = min(max(0, current), count - 1)

        switch direction {
        case .right:
            return (clamped + 1) % count
        case .left:
            return (clamped - 1 + count) % count
        case .down:
            let next = clamped + cols
            if next < count {
                return next
            }
            // If we're not on the last row, jump to the last item on the last row;
            // if already on the last row, wrap to the same column in row 0.
            let currentRow = clamped / cols
            let lastRow = (count - 1) / cols
            if currentRow < lastRow {
                return count - 1
            } else {
                return clamped % cols
            }
        case .up:
            let prev = clamped - cols
            if prev >= 0 {
                return prev
            }
            // Wrap from row 0 to the bottom-most item in the same column (or last item if shorter).
            let col = clamped % cols
            let lastRow = (count - 1) / cols
            let candidate = lastRow * cols + col
            if candidate < count {
                return candidate
            }
            let prevRowCandidate = (lastRow - 1) * cols + col
            return prevRowCandidate >= 0 ? prevRowCandidate : (count - 1)
        }
    }
}
