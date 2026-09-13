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
        return normalizedLevel(fromDecibels: decibels)
    }

    public static func normalizedLevel(fromDecibels decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
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

    public static func advancingWaveform(
        _ samples: [Float],
        incoming level: Float,
        count: Int
    ) -> [Float] {
        let sampleCount = max(1, count)
        let safeLevel = min(max(level.isFinite ? level : 0, 0), 1)
        var updated = Array(samples.suffix(sampleCount - 1))
        updated.append(0.05 + safeLevel * 0.9)
        if updated.count < sampleCount {
            updated.insert(contentsOf: repeatElement(0.05, count: sampleCount - updated.count), at: 0)
        }
        return updated
    }

    /// Produces a frame visual determinístico sem publicar estado durante a
    /// renderização do SwiftUI. Silêncio é sempre uma linha plana; com áudio,
    /// fase e posição formam uma onda contínua cuja altura segue a amplitude.
    public static func animatedBarLevel(
        audioLevel: Float,
        phase: TimeInterval,
        index: Int,
        count: Int
    ) -> Float {
        let safeLevel = min(max(audioLevel.isFinite ? audioLevel : 0, 0), 1)
        guard safeLevel > 0.01 else { return 0.05 }

        let safeCount = max(1, count)
        let position = Double(index) / Double(safeCount)
        let temporalFrequency = 7.0 + Double(safeLevel) * 7.0
        let primary = abs(sin(phase * temporalFrequency + position * .pi * 4.0))
        let secondary = abs(sin(phase * 3.1 - position * .pi * 7.0))
        let envelope = 0.24 + primary * 0.58 + secondary * 0.18
        return min(0.95, 0.05 + safeLevel * 0.9 * Float(envelope))
    }
}
