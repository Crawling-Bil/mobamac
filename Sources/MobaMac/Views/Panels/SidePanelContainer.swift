import SwiftUI

/// Which right-hand panel the detail column is showing. One case today;
/// SFTP, Snippets and Logs are meant to become cases here rather than grow a
/// second panel slot, so that only one panel ever competes with the terminal
/// for width.
enum DetailPanel: String, Identifiable, Hashable {
    case networkTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .networkTools: return "Network Tools"
        }
    }

    var icon: String {
        switch self {
        case .networkTools: return "network"
        }
    }
}

/// Chrome shared by everything that shows up as a right-hand panel: a header
/// with the panel's name, a minimize control, and a close control.
///
/// Minimizing collapses the panel to a narrow strip instead of closing it.
/// That distinction is the whole point — the strip keeps the panel's model
/// alive and only hides it, so a long ping result is still there when it is
/// reopened, while close means close.
struct SidePanelContainer<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isMinimized: Bool
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if isMinimized {
            minimizedStrip
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 620)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
            Spacer()
            Button {
                isMinimized = true
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Collapse \(title) to a strip. Whatever is in it stays loaded.")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(title).")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    private var minimizedStrip: some View {
        VStack(spacing: 12) {
            Button {
                isMinimized = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand \(title).")

            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(title)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(title).")
        }
        .padding(.vertical, 10)
        .frame(width: 32)
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}
