import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        isModalInPresentation = true

        let model = ShareModel(onCancel: { [weak self] in
            self?.dismissWithoutUploading()
        }, onFinish: { [weak self] in
            self?.finish()
        })
        self.model = model

        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        if UIDevice.current.userInterfaceIdiom == .pad {
            let width = min(UIScreen.main.bounds.width * 0.75, 800)
            preferredContentSize = CGSize(width: width, height: 560)
        }

        Task {
            let items = await ShareItemLoader.load(from: extensionContext)
            model.setItems(items)
        }
    }

    private func dismissWithoutUploading() {
        extensionContext?.completeRequest(returningItems: extensionContext?.inputItems,
                                          completionHandler: nil)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
