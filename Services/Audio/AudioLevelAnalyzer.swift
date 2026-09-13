import Foundation

public enum AudioLevelAnalyzer {
    public static func rootMeanSquare<S: Sequence>(of samples: S) -> Float where S.Element == Float {
        var sum: Double = 0
        var count = 0

        for sample in samples where sample.isFinite {
            let clamped = min(max(sample, -1), 1)
            sum += Double(clamped * clamped)
            count += 1
        }

        guard count > 0 else { return 0 }
        return Float(sqrt(sum / Double(count)))
    }

    public static func normalizedLevel(fromRMS rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let noiseFloor: Float = -55
        guard decibels > noiseFloor else { return 0 }
        return min(max((decibels - noiseFloor) / -noiseFloor, 0), 1)
    }

    public static func smoothed(previous: Float, incoming: Float) -> Float {
        let safePrevious = min(max(previous.isFinite ? previous : 0, 0), 1)
        let safeIncoming = min(max(incoming.isFinite ? incoming : 0, 0), 1)
        let response: Float = safeIncoming > safePrevious ? 0.72 : 0.18
        return safePrevious + ((safeIncoming - safePrevious) * response)
    }
}
