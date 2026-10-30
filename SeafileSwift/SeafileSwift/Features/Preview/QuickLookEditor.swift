import QuickLook
import SwiftUI
import UIKit

struct MarkupRequest: Identifiable {
    let id = UUID()
    let url: URL
}

struct QuickLookEditor: UIViewControllerRepresentable {
    let url: URL
    let onEdited: (URL) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onEdited: onEdited, onClose: onClose)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        DispatchQueue.main.async {
            guard !context.coordinator.didPresent else { return }
            context.coordinator.didPresent = true
            let controller = QLPreviewController()
            controller.dataSource = context.coordinator
            controller.delegate = context.coordinator
            host.present(controller, animated: true)
        }
        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let onEdited: (URL) -> Void
        let onClose: () -> Void
        var didPresent = false

        init(url: URL, onEdited: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
            self.url = url
            self.onEdited = onEdited
            self.onClose = onClose
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        func previewController(_ controller: QLPreviewController,
                               editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .createCopy
        }

        func previewController(_ controller: QLPreviewController,
                               didSaveEditedCopyOf previewItem: QLPreviewItem,
                               at modifiedContentsURL: URL) {
            onEdited(modifiedContentsURL)
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            onClose()
        }
    }
}
