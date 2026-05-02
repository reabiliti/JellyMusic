import Foundation

enum PlaybackQueuePolicy {
    static func nextIndex(
        queueCount: Int,
        currentIndex: Int,
        repeatMode: RepeatMode,
        shuffle: Bool,
        automatic: Bool
    ) -> Int? {
        guard queueCount > 0, currentIndex >= 0, currentIndex < queueCount else { return nil }

        if automatic, repeatMode == .one {
            return currentIndex
        }

        if shuffle, queueCount > 1 {
            var candidates = Array(0..<queueCount)
            candidates.removeAll { $0 == currentIndex }
            return candidates.randomElement()
        }

        let next = currentIndex + 1
        if next < queueCount {
            return next
        }

        return repeatMode == .all ? 0 : nil
    }

    static func previousIndex(queueCount: Int, currentIndex: Int) -> Int? {
        guard queueCount > 0, currentIndex >= 0, currentIndex < queueCount else { return nil }
        return currentIndex > 0 ? currentIndex - 1 : 0
    }
}
