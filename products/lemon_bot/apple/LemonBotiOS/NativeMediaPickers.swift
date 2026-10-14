import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct SelectedPhotoPicker: UIViewControllerRepresentable {
    let capture: SharedCapture
    let completion: (Result<SharedCapture, Error>) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = max(1, 6 - capture.files.count)
        configuration.filter = .any(of: [.images, .videos])
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: SelectedPhotoPicker
        init(parent: SelectedPhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else { parent.completion(.success(parent.capture)); return }
            Task {
                var capture = parent.capture
                do {
                    for result in results {
                        let provider = result.itemProvider
                        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
                            guard let type = UTType($0) else { return false }
                            return type.conforms(to: .image) || type.conforms(to: .movie)
                        }) else { throw CaptureError.message("The selected photo or video has no readable media representation.") }
                        let file: SharedFile = try await withCheckedThrowingContinuation { continuation in
                            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                                do {
                                    if let error { throw error }
                                    guard let url else { throw CaptureError.message("The selected photo or video could not be downloaded from Photos.") }
                                    let copied = try ShareInbox.copy(url, filename: provider.suggestedName ?? url.lastPathComponent, mime: UTType(identifier)?.preferredMIMEType, into: capture)
                                    continuation.resume(returning: copied)
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                        capture.files.append(file)
                        try ShareInbox.save(capture)
                    }
                    parent.completion(.success(capture))
                } catch {
                    capture.error = error.localizedDescription
                    try? ShareInbox.save(capture)
                    parent.completion(.failure(error))
                }
            }
        }
    }
}

struct ExplicitCameraPicker: UIViewControllerRepresentable {
    let capture: SharedCapture
    let completion: (Result<SharedCapture, Error>) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ExplicitCameraPicker
        init(parent: ExplicitCameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.completion(.success(parent.capture)) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            var capture = parent.capture
            do {
                guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) else {
                    throw CaptureError.message("The camera did not return a readable photograph.")
                }
                let fileID = UUID().uuidString
                let storedName = fileID + ".jpg"
                let url = try ShareInbox.directory(capture.id).appendingPathComponent(storedName)
                guard data.count <= 25 * 1024 * 1024 else { throw CaptureError.message("The captured photo exceeds the 25 MiB attachment limit.") }
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                capture.files.append(SharedFile(id: fileID, filename: "Camera photo.jpg", storedName: storedName, mime: "image/jpeg", size: Int64(data.count), uploadNonce: UUID().uuidString))
                try ShareInbox.save(capture)
                parent.completion(.success(capture))
            } catch {
                capture.error = error.localizedDescription
                try? ShareInbox.save(capture)
                parent.completion(.failure(error))
            }
        }
    }
}
