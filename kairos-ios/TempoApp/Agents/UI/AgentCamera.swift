import SwiftUI
import UIKit

/// Takes a photo of a letter, bill or form (or picks one from Photos when there's no camera) and hands back a
/// small JPEG: at most 1600 pixels on the long side, quality 0.7. Quick to send, still easy to read.
struct AgentCamera: UIViewControllerRepresentable {
    enum Source: String, Identifiable {
        case camera, library
        var id: String { rawValue }
    }

    var source: Source = .camera
    /// The JPEG, or nil if the person cancelled or the photo couldn't be used.
    let onPhoto: (Data?) -> Void

    static var hasCamera: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if source == .camera, Self.hasCamera {
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPhoto: onPhoto) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPhoto: (Data?) -> Void
        init(onPhoto: @escaping (Data?) -> Void) { self.onPhoto = onPhoto }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            onPhoto(image.flatMap { AgentCamera.jpeg(from: $0) })
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPhoto(nil) }
    }

    /// Shrinks a photo to `maxSide` pixels on the long side (upright) and encodes it as JPEG.
    nonisolated static func jpeg(from image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let shrink = min(1, maxSide / max(pixels.width, pixels.height))
        let target = CGSize(width: (pixels.width * shrink).rounded(), height: (pixels.height * shrink).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
