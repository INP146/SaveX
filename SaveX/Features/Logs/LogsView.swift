import SwiftUI
import UIKit

struct LogsView: View {
    @ObservedObject var downloadCenter: DownloadCenter

    var body: some View {
        NavigationStack {
            ZStack {
                SaveXBackground()

                VStack(alignment: .leading, spacing: 18) {
                    header

                    if downloadCenter.logs.isEmpty {
                        emptyState
                        Spacer(minLength: 0)
                    } else {
                        logConsole
                    }
                }
                .padding(SaveXPageLayout.standardInsets)
            }
            .saveXNavigationChrome()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Logs")
                .font(.system(size: 34, weight: .bold, design: .rounded))

            Spacer()

            Button {
                UIPasteboard.general.string = logText
            } label: {
                Image(systemName: "doc.on.doc")
                    .saveXGlassIcon()
            }
            .saveXGlassIconButton()
            .disabled(downloadCenter.logs.isEmpty)
            .accessibilityLabel("Copy logs")

            Button {
                downloadCenter.clearLogs()
            } label: {
                Image(systemName: "trash")
                    .saveXGlassIcon()
            }
            .saveXGlassIconButton()
            .disabled(downloadCenter.logs.isEmpty)
            .accessibilityLabel("Clear logs")
        }
        .padding(.top, 12)
    }

    private var logConsole: some View {
        LogTextView(logs: Array(downloadCenter.logs.reversed()))
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var logText: String {
        downloadCenter.logs
            .reversed()
            .map(\.consoleLine)
            .joined(separator: "\n")
    }

    private var emptyState: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("No logs yet")
                    .font(.headline)

                Text("Queue a download and trace events will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LogTextView: UIViewRepresentable {
    let logs: [DownloadLogEntry]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ConsoleScrollView {
        let scrollView = ConsoleScrollView()
        context.coordinator.textView = scrollView.textView
        return scrollView
    }

    func updateUIView(_ scrollView: ConsoleScrollView, context: Context) {
        let textView = scrollView.textView
        let selectedRange = textView.selectedRange
        let attributedText = NSMutableAttributedString()
        for (index, log) in logs.enumerated() {
            if index > 0 {
                attributedText.append(NSAttributedString(string: "\n", attributes: DownloadLogEntry.baseConsoleAttributes))
            }
            attributedText.append(log.nsConsoleLine)
        }
        if attributedText.length == 0 {
            attributedText.append(NSAttributedString(string: " ", attributes: DownloadLogEntry.baseConsoleAttributes))
        }
        textView.backgroundColor = .clear
        textView.textColor = .logText
        textView.typingAttributes = DownloadLogEntry.baseConsoleAttributes
        textView.attributedText = attributedText
        scrollView.updateTextSize()
        if selectedRange.location != NSNotFound,
           selectedRange.location <= attributedText.length {
            textView.selectedRange = selectedRange
        }
    }

    final class Coordinator {
        weak var textView: UITextView?
    }
}

private final class ConsoleScrollView: UIScrollView {
    let textView = UITextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTextSize()
    }

    func updateTextSize() {
        let targetSize = textView.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        let fittedSize = CGSize(
            width: max(bounds.width, ceil(targetSize.width)),
            height: max(bounds.height, ceil(targetSize.height))
        )
        textView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        overrideUserInterfaceStyle = .dark
        alwaysBounceVertical = true
        alwaysBounceHorizontal = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = true
        indicatorStyle = .white
        bounces = true

        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.overrideUserInterfaceStyle = .dark
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textColor = .logText
        textView.tintColor = .systemBlue
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.lineBreakMode = .byClipping
        textView.textContainer.size = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.typingAttributes = DownloadLogEntry.baseConsoleAttributes
        addSubview(textView)
    }
}

private extension DownloadLogEntry {
    static var baseConsoleAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: UIColor.logText,
            .font: UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
            .paragraphStyle: consoleParagraphStyle,
        ]
    }

    static var consoleParagraphStyle: NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping
        return paragraphStyle
    }

    var nsConsoleLine: NSAttributedString {
        let line = NSMutableAttributedString()
        line.append(segment("[\(timeText)] ", color: .logMeta))
        line.append(segment(kind.consoleLabel, color: kind.uiConsoleColor))
        line.append(segment(tweetConsoleText, color: .logMeta))
        line.append(segment(" \(title) ", color: kind.uiConsoleColor))
        line.append(segment("- \(message)", color: .logText))
        return line
    }

    var consoleLine: String {
        let tweet = tweetID.map { " tweet=\($0)" } ?? ""
        return "[\(timeText)] \(kind.consoleLabel)\(tweet) \(title) - \(message)"
    }

    var timeText: String {
        createdAt.formatted(.dateTime.hour().minute().second())
    }

    var tweetConsoleText: String {
        tweetID.map { " tweet=\($0)" } ?? ""
    }

    private func segment(_ text: String, color: UIColor) -> NSAttributedString {
        return NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular),
                .paragraphStyle: Self.consoleParagraphStyle,
            ]
        )
    }
}

private extension DownloadLogEntry.Kind {
    var consoleLabel: String {
        switch self {
        case .info:
            return "INFO "
        case .success:
            return "OK   "
        case .warning:
            return "WARN "
        case .error:
            return "ERROR"
        }
    }

    var uiConsoleColor: UIColor {
        switch self {
        case .info:
            return .logBlue
        case .success:
            return .logGreen
        case .warning:
            return .logOrange
        case .error:
            return .logRed
        }
    }
}

private extension UIColor {
    static let logText = UIColor(white: 0.96, alpha: 1)
    static let logMeta = UIColor(white: 0.68, alpha: 1)
    static let logBlue = UIColor(red: 0.22, green: 0.62, blue: 1.00, alpha: 1)
    static let logGreen = UIColor(red: 0.18, green: 0.86, blue: 0.42, alpha: 1)
    static let logOrange = UIColor(red: 1.00, green: 0.68, blue: 0.20, alpha: 1)
    static let logRed = UIColor(red: 1.00, green: 0.32, blue: 0.36, alpha: 1)
}

#Preview("Logs") {
    LogsView(downloadCenter: .preview)
}
