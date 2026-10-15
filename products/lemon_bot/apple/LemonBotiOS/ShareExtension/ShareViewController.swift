import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let model = ShareReviewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.context = extensionContext
        let host = UIHostingController(rootView: ShareReviewView(model: model))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
final class ShareReviewModel: ObservableObject {
    @Published var capture: SharedCapture?
    @Published var text = ""
    @Published var loading = false
    @Published var error: String?
    @Published var sharingUnavailable = false
    var context: NSExtensionContext?

    func load() async {
        loading = true
        error = nil
        sharingUnavailable = false
        if let old = capture { try? ShareInbox.discard(old) }
        capture = nil
        var draft: SharedCapture?
        do {
            var result = try ShareInbox.begin()
            draft = result
            let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            for item in items {
                if let itemText = item.attributedContentText?.string, !itemText.isEmpty {
                    result.text += (result.text.isEmpty ? "" : "\n") + itemText
                }
                for provider in item.attachments ?? [] {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        guard result.files.count < 6 else { throw CaptureError.message("A message supports at most six selected files.") }
                        result.files.append(try await copyFileURL(provider, into: result))
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { identifier in
                        guard let type = UTType(identifier) else { return false }
                        return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
                    }) {
                        guard result.files.count < 6 else { throw CaptureError.message("A message supports at most six selected files.") }
                        result.files.append(try await copyRepresentation(provider, type: type, into: result))
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                        let value = try await loadItem(provider, type: UTType.url.identifier)
                        guard let url = value as? URL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                            throw CaptureError.message("Only selected HTTP or HTTPS links can be staged as text.")
                        }
                        result.text += (result.text.isEmpty ? "" : "\n") + url.absoluteString
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        let value = try await loadItem(provider, type: UTType.plainText.identifier)
                        let selectedText: String
                        if let string = value as? String { selectedText = string }
                        else if let data = value as? Data, let string = String(data: data, encoding: .utf8) { selectedText = string }
                        else { throw CaptureError.message("The selected text could not be read as UTF-8.") }
                        if !result.text.contains(selectedText) {
                            result.text += (result.text.isEmpty ? "" : "\n") + selectedText
                        }
                    } else {
                        throw CaptureError.message("This shared item has no readable text, link or file representation.")
                    }
                }
            }
            guard !result.text.isEmpty || !result.files.isEmpty else { throw CaptureError.message("No user-selected text or file was supplied.") }
            guard result.text.utf8.count <= 1024 * 1024 else { throw CaptureError.message("Selected text exceeds 1 MiB.") }
            capture = result
            text = result.text
        } catch {
            self.error = error.localizedDescription
            if case .sharingUnavailable? = error as? CaptureError { sharingUnavailable = true }
            if let draft { try? ShareInbox.discard(draft) }
        }
        loading = false
    }

    private func loadItem(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: CaptureError.message("The selected item was not supplied by its source app.")) }
            }
        }
    }

    private func copyFileURL(_ provider: NSItemProvider, into capture: SharedCapture) async throws -> SharedFile {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                do {
                    if let error { throw error }
                    guard let url = value as? URL else { throw CaptureError.message("The selected file URL could not be read.") }
                    continuation.resume(returning: try ShareInbox.copy(url, into: capture))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func copyRepresentation(_ provider: NSItemProvider, type: String, into capture: SharedCapture) async throws -> SharedFile {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CaptureError.message("The selected file could not be loaded from its source app.") }
                    // Provider URLs cease to exist when this callback returns.
                    let file = try ShareInbox.copy(url, filename: provider.suggestedName ?? url.lastPathComponent, mime: UTType(type)?.preferredMIMEType, into: capture)
                    continuation.resume(returning: file)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func save() {
        guard var capture else { return }
        do {
            capture.text = text
            guard !text.isEmpty || !capture.files.isEmpty else { throw CaptureError.message("Add selected text or a file before saving.") }
            guard text.utf8.count <= 1024 * 1024 else { throw CaptureError.message("Selected text exceeds 1 MiB.") }
            try ShareInbox.save(capture)
            context?.completeRequest(returningItems: [], completionHandler: nil)
        } catch { self.error = error.localizedDescription }
    }

    func cancel() {
        if let capture { try? ShareInbox.discard(capture) }
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

struct ShareReviewView: View {
    @ObservedObject var model: ShareReviewModel
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !model.sharingUnavailable {
                        Text("Save only these selected items. Open Lemon Bot, choose an account and conversation, then attach them to its unsent composer. Nothing is uploaded or sent from this extension.")
                    }
                    if model.loading { ProgressView("Copying selected content…") }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        if !model.sharingUnavailable {
                            Button("Read selected items again") { Task { await model.load() } }
                        }
                    }
                }
                if let capture = model.capture {
                    Section("Review selected text") { TextEditor(text: $model.text).frame(minHeight: 120) }
                    Section("Files copied to Lemon Bot") {
                        ForEach(capture.files) { file in
                            VStack(alignment: .leading) {
                                Text(file.filename)
                                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Save to Lemon Bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: model.cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    if !model.sharingUnavailable {
                        Button("Save for review", action: model.save).disabled(model.capture == nil || model.loading)
                    }
                }
            }
        }
    }
}
