import SwiftUI
import UniformTypeIdentifiers

/// The app window: the model, or an invitation to pick one.
struct ContentView: View {
    @EnvironmentObject private var model: ViewerModel

    @State private var isChoosingFile = false
    @State private var isDropTarget = false

    private static let glbType = UTType(filenameExtension: "glb") ?? .data

    var body: some View {
        NavigationStack {
            Group {
                if let url = model.url {
                    GLBViewerView(url: url)
                } else {
                    EmptyState(isDropTarget: isDropTarget)
                }
            }
            .navigationTitle(model.title)
            .toolbar { toolbar }
        }
        .frame(minWidth: 640, minHeight: 420)
        .overlay(alignment: .bottom) { dropHighlight }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [Self.glbType],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.open(url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: acceptDrop)
        .onAppear { model.refreshDefaultHandlerState() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                isChoosingFile = true
            } label: {
                Label("Open", systemImage: "folder")
            }
            .keyboardShortcut("o")
            .help("Open a .glb model (⌘O)")

            if let url = model.url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal", systemImage: "arrow.right.circle")
                }
                .help("Reveal in Finder")
            }

            if !model.isDefaultHandler {
                Button {
                    model.makeDefaultHandler()
                } label: {
                    Label("Use for .glb", systemImage: "checkmark.seal")
                }
                .help("Make this app open .glb files when you double-click them")
            }
        }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isDropTarget {
            Text("Drop to open")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 20)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in model.open(url) }
            }
        }
        return true
    }
}

private struct EmptyState: View {
    let isDropTarget: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Open a .glb model")
                .font(.title3)
            Text("Drag one here, press ⌘O, or double-click one in Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Draco, Meshopt and KTX2 compressed models work, and animations play.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}
