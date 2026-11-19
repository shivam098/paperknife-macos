import AppKit
import SwiftUI

/// The window's content: the message bar, the empty state or the workspace, and the status bar.
struct MainView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.banner {
                NoticeView(severity: banner.severity, title: banner.title, message: banner.message) {
                    model.banner = nil
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if model.isOpen {
                WorkspaceView(model: model)
            } else {
                EmptyStateView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            StatusBar(model: model)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == "pdf" }) else {
                return false
            }

            Task { await model.open(path: url.path) }
            return true
        }
    }
}

struct EmptyStateView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 12) {
            Text("PaperKnife")
                .font(.largeTitle)
                .bold()
            Text("Edit PDFs on this device. Your files are never uploaded.")
                .multilineTextAlignment(.center)
            Button("Open a PDF") {
                Task { await model.openWithPanel() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canOpen)
            Text("or drop a PDF here")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 440)
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            PageList(model: model)
                .frame(width: 140)
            Divider()
            PageCanvas(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            EditPane(model: model)
                .frame(width: 360)
        }
    }
}

struct PageList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        List(selection: Binding(
            get: { model.isOpen ? model.pageIndex : nil },
            set: { index in
                if let index {
                    Task { await model.selectPage(index) }
                }
            })) {
            ForEach(0..<model.state.pageCount, id: \.self) { index in
                Text("Page \(index + 1)")
                    .tag(index)
            }
        }
        .disabled(!model.canUseDocument)
        .accessibilityLabel("Pages")
    }
}

/// The page, with the selected text's box over it. A click selects the text under the pointer.
struct PageCanvas: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let page = model.page {
                        ZStack(alignment: .topLeading) {
                            Image(page.image, scale: page.scale, label: Text("Page"))
                                .accessibilityIdentifier("page")
                                .gesture(SpatialTapGesture().onEnded { value in
                                    Task { await model.click(at: value.location) }
                                })
                            if let box = model.selectionBox {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.13))
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: 2))
                                    .frame(width: box.width, height: box.height)
                                    .offset(x: box.minX, y: box.minY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
                        .padding(1)
                        .border(Color(nsColor: .separatorColor))
                    }
                }
                .padding(24)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct EditPane: View {
    @ObservedObject var model: EditorModel
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit text")
                .font(.title2)
            if !model.pageBlockers.isEmpty {
                NoticeView(severity: .warning, title: "Editing is off on this page", message: model.pageBlockers.joined(separator: " "))
            }

            Text(model.editHint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected text")
                TextField("Selected text", text: $model.editText)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($textFocused)
                    .disabled(!model.canEditText)
                    .onSubmit {
                        Task { await model.applyEdit(deleting: false) }
                    }
                    .onExitCommand {
                        model.reset()
                    }
            }

            if !model.fontInfo.isEmpty {
                Text(model.fontInfo)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("Apply") {
                    Task { await model.applyEdit(deleting: false) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApply)
                Button("Reset") {
                    model.reset()
                }
                .disabled(!model.canReset)
                Button("Delete Text") {
                    Task { await model.applyEdit(deleting: true) }
                }
                .disabled(!model.canDeleteText)
            }

            Text("PaperKnife changes only the selected text. After every edit it re-reads the saved result and compares the whole page; if anything else would change, the edit is cancelled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Text on this page")
                .font(.headline)
                .padding(.top, 8)
            RunList(model: model)
        }
        .padding(16)
        .onChange(of: model.focusRequest) { _ in
            // After the field is enabled for the new selection.
            Task {
                await Task.yield()
                textFocused = true
            }
        }
    }
}

struct RunList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedRunIndex },
            set: { index in
                if let index {
                    model.selectRun(at: index)
                }
            })) {
            ForEach(Array(model.runs.enumerated()), id: \.offset) { index, run in
                Text(EditorModel.listText(run))
                    .lineLimit(1)
                    .tag(index)
            }
        }
        .disabled(!model.canUseDocument)
        .accessibilityLabel("Text on this page")
    }
}

struct StatusBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack {
            Text(model.statusText)
                .font(.caption)
            Spacer()
            if model.busy {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 160)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A message with its severity's color and symbol, closable when `close` is given.
struct NoticeView: View {
    var severity: Severity
    var title: String
    var message: String
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .bold()
                if !message.isEmpty {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.4)))
    }

    private var symbol: String {
        switch severity {
        case .informational: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch severity {
        case .informational: .blue
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
