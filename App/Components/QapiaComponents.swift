import AppKit
import QapiaCore
import SwiftUI

enum QapiaTheme: String {
    case light
    case dark

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var switchTitle: String {
        switch self {
        case .light: "Usar tema escuro"
        case .dark: "Usar tema claro"
        }
    }

    var switchIcon: String {
        switch self {
        case .light: "moon.fill"
        case .dark: "sun.max.fill"
        }
    }

    mutating func toggle() {
        self = self == .dark ? .light : .dark
    }
}

enum QapiaColors {
    static let canvas = dynamic(
        light: NSColor(calibratedRed: 0.961, green: 0.965, blue: 0.973, alpha: 1),
        dark: NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
    )
    static let sidebar = dynamic(
        light: NSColor(calibratedRed: 0.925, green: 0.933, blue: 0.949, alpha: 0.92),
        dark: NSColor(calibratedRed: 0.071, green: 0.082, blue: 0.102, alpha: 0.94)
    )
    static let surface = dynamic(
        light: .white,
        dark: NSColor(calibratedRed: 0.09, green: 0.102, blue: 0.125, alpha: 1)
    )
    static let surfaceRaised = dynamic(
        light: .white,
        dark: NSColor(calibratedRed: 0.114, green: 0.129, blue: 0.161, alpha: 1)
    )
    static let surfaceHover = dynamic(
        light: NSColor(calibratedRed: 0.941, green: 0.949, blue: 0.965, alpha: 1),
        dark: NSColor(calibratedRed: 0.133, green: 0.153, blue: 0.192, alpha: 1)
    )
    static let divider = dynamic(
        light: NSColor(calibratedRed: 0.867, green: 0.882, blue: 0.91, alpha: 1),
        dark: NSColor(calibratedRed: 0.165, green: 0.188, blue: 0.227, alpha: 1)
    )
    static let accent = dynamic(
        light: NSColor(calibratedRed: 0.396, green: 0.455, blue: 0.969, alpha: 1),
        dark: NSColor(calibratedRed: 0.51, green: 0.565, blue: 1, alpha: 1)
    )
    static let signalEdge = dynamic(
        light: NSColor(calibratedRed: 0.325, green: 0.788, blue: 0.753, alpha: 1),
        dark: NSColor(calibratedRed: 0.404, green: 0.843, blue: 0.808, alpha: 1)
    )
    static let recording = dynamic(
        light: NSColor(calibratedRed: 0.937, green: 0.322, blue: 0.38, alpha: 1),
        dark: NSColor(calibratedRed: 1, green: 0.4, blue: 0.455, alpha: 1)
    )
    static let paused = dynamic(
        light: NSColor(calibratedRed: 0.847, green: 0.588, blue: 0.157, alpha: 1),
        dark: NSColor(calibratedRed: 0.941, green: 0.722, blue: 0.294, alpha: 1)
    )
    static let success = dynamic(
        light: NSColor(calibratedRed: 0.22, green: 0.725, blue: 0.447, alpha: 1),
        dark: NSColor(calibratedRed: 0.29, green: 0.788, blue: 0.522, alpha: 1)
    )
    static let audioStage = dynamic(
        light: NSColor(calibratedRed: 0.925, green: 0.941, blue: 0.992, alpha: 1),
        dark: NSColor(calibratedRed: 0.043, green: 0.071, blue: 0.145, alpha: 1)
    )
    static let audioStageText = dynamic(
        light: NSColor(calibratedRed: 0.075, green: 0.094, blue: 0.165, alpha: 1),
        dark: .white
    )
    static let audioStageMuted = dynamic(
        light: NSColor(calibratedRed: 0.31, green: 0.337, blue: 0.42, alpha: 1),
        dark: NSColor.white.withAlphaComponent(0.62)
    )
    static let audioStageControl = dynamic(
        light: NSColor(calibratedRed: 0.805, green: 0.827, blue: 0.91, alpha: 0.74),
        dark: NSColor.white.withAlphaComponent(0.12)
    )
    static let audioStageBadge = dynamic(
        light: NSColor(calibratedRed: 0.84, green: 0.857, blue: 0.925, alpha: 0.72),
        dark: NSColor.white.withAlphaComponent(0.075)
    )
    static let audioStageBorder = dynamic(
        light: NSColor(calibratedRed: 0.73, green: 0.765, blue: 0.88, alpha: 0.7),
        dark: NSColor.white.withAlphaComponent(0.1)
    )

    static let signalGradient = LinearGradient(
        colors: [accent, signalEdge],
        startPoint: .leading,
        endPoint: .trailing
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

@MainActor
private enum QapiaAssets {
    static let appIcon: NSImage = {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            return icon
        }
        return NSApp.applicationIconImage
    }()
}

struct ThemeToggleButton: View {
    let theme: QapiaTheme
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: theme.switchIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QapiaColors.accent)
                .frame(width: 30, height: 30)
                .background(QapiaColors.surfaceHover.opacity(isHovering ? 1 : 0.78))
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(QapiaColors.divider.opacity(0.9), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help(theme.switchTitle)
        .accessibilityLabel(theme.switchTitle)
    }
}

struct SurfaceCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QapiaColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(QapiaColors.divider.opacity(0.82), lineWidth: 1)
            }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    private let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .tracking(-0.45)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

struct StatusIndicator: View {
    let title: String
    let color: Color
    var pulses = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if pulses {
                    Circle()
                        .fill(color.opacity(0.18))
                        .frame(width: 16, height: 16)
                }
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(color.opacity(0.11))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

struct QapiaActionButton: View {
    enum Kind {
        case primary
        case secondary
    }

    let title: String
    let kind: Kind
    var systemImage: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 15)
            .frame(height: 38)
            .frame(minWidth: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(QapiaModernButtonStyle(kind: kind, isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}

private struct QapiaModernButtonStyle: ButtonStyle {
    let kind: QapiaActionButton.Kind
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(kind == .primary ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(kind == .primary ? AnyShapeStyle(QapiaColors.signalGradient) : AnyShapeStyle(QapiaColors.surfaceRaised))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(isHovering && kind == .primary ? 0.08 : 0))
                    }
            }
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(QapiaColors.divider, lineWidth: 1)
                }
            }
            .shadow(color: kind == .primary ? QapiaColors.accent.opacity(0.2) : .clear, radius: 12, y: 5)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct RecordingControlButton: View {
    enum Role {
        case primary
        case neutral
        case stop
    }

    let title: String
    let systemImage: String
    let role: Role
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 48, height: 48)
                    .background(background)
                    .clipShape(Circle())
                    .overlay { Circle().stroke(QapiaColors.audioStageBorder, lineWidth: 1) }
                    .scaleEffect(isHovering ? 1.035 : 1)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(QapiaColors.audioStageMuted)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .stop ? Color.white : QapiaColors.audioStageText)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var background: some View {
        switch role {
        case .primary: QapiaColors.signalGradient
        case .neutral: QapiaColors.audioStageControl.opacity(isHovering ? 1 : 0.82)
        case .stop: QapiaColors.recording.opacity(isHovering ? 1 : 0.88)
        }
    }
}

struct WaveformView: View {
    let level: Float
    let isActive: Bool
    let barCount: Int
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var samples: [CGFloat]

    init(level: Float, isActive: Bool, barCount: Int = 40, height: CGFloat = 84) {
        self.level = level
        self.isActive = isActive
        self.barCount = max(1, barCount)
        self.height = height
        _samples = State(initialValue: Array(repeating: 0.035, count: max(1, barCount)))
    }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let width = max(2.5, (proxy.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(QapiaColors.signalGradient)
                        .frame(width: width, height: max(4, min(proxy.size.height, proxy.size.height * samples[index])))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: height)
        .opacity(isActive ? 1 : 0.38)
        .onChange(of: level) { _, newLevel in
            guard isActive else { return }
            var updated = samples
            if !updated.isEmpty { updated.removeFirst() }
            let safeLevel = CGFloat(min(max(newLevel.isFinite ? newLevel : 0, 0), 1))
            updated.append(0.05 + safeLevel * 0.9)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.09)) {
                samples = updated
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nível de áudio")
        .accessibilityValue(accessibilityLevel)
    }

    private var accessibilityLevel: String {
        switch level {
        case ..<0.12: "baixo"
        case ..<0.55: "médio"
        default: "alto"
        }
    }
}

struct ProcessingActivityBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let segmentWidth = max(52, proxy.size.width * 0.28)
                let duration = 1.35
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration) / duration
                let travel = proxy.size.width + segmentWidth

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(QapiaColors.surfaceHover)
                    Capsule(style: .continuous)
                        .fill(QapiaColors.signalGradient)
                        .frame(width: segmentWidth)
                        .offset(x: reduceMotion ? 0 : -segmentWidth + travel * phase)
                }
                .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processamento em andamento")
    }
}

struct BrandSignalMark: View {
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: QapiaAssets.appIcon)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .shadow(color: QapiaColors.accent.opacity(0.2), radius: 8, y: 3)
        .accessibilityLabel("Ícone do QAP.ia")
    }
}

struct TemplatePicker: View {
    let templates: [SummaryTemplate]
    @Binding var selection: SummaryTemplate

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(QapiaColors.accent)
            Text("Template")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("Template", selection: $selection) {
                ForEach(templates) { template in
                    Text(template.rawValue).tag(template)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(QapiaColors.surfaceHover)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct TemplateConfigurationView: View {
    let templates: [SummaryTemplate]
    @Binding var selection: SummaryTemplate

    var body: some View {
        TemplatePicker(templates: templates, selection: $selection)
            .fixedSize()
    }
}

struct ProcessingStepRow: View {
    let title: String
    let state: String
    let color: Color
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle.dotted")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .font(.system(size: 16))
                .frame(width: 20)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text(state)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct SidebarButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .symbolRenderingMode(.hierarchical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .background(isSelected || isHovering ? QapiaColors.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
    }
}

struct MeetingHistoryRow: View {
    let meeting: Meeting
    let isSelected: Bool
    let deleteAction: (() -> Void)?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            Button(action: action) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stateColor)
                        .frame(width: 3, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(meeting.sidebarMetadata)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 9)
                .frame(height: 48)
            }
            .buttonStyle(.plain)

            if let deleteAction {
                Button(role: .destructive, action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(QapiaColors.recording)
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isSelected ? 1 : 0.48)
                .help("Excluir gravação")
                .accessibilityLabel("Excluir \(meeting.title)")
            }
        }
        .background(isSelected || isHovering ? QapiaColors.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private var stateColor: Color {
        switch meeting.state {
        case .completed: QapiaColors.success
        case .failed, .recording, .paused: QapiaColors.recording
        default: QapiaColors.accent
        }
    }
}
