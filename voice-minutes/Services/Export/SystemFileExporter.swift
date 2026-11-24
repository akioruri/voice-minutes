import Foundation

#if os(iOS)
import UIKit

/// Presents the platform-native save experience and cleans up temporary files.
@MainActor
enum SystemFileExporter {
    private static var activeCoordinator: Coordinator?

    static func save(
        fileURL: URL,
        suggestedFilename: String,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard let presenter = topViewController() else {
            completion(.failure(SystemFileExporterError.noPresenter))
            return
        }

        let coordinator = Coordinator(
            fileURL: fileURL,
            completion: completion
        )
        activeCoordinator = coordinator

        let picker = UIDocumentPickerViewController(
            forExporting: [fileURL],
            asCopy: true
        )
        picker.delegate = coordinator
        picker.shouldShowFileExtensions = true
        presenter.present(picker, animated: true)
    }

    private static func topViewController(
        from base: UIViewController? = nil
    ) -> UIViewController? {
        let base = base ?? keyWindow()?.rootViewController

        if let presented = base?.presentedViewController {
            return topViewController(from: presented)
        }

        if let navigation = base as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }

        if let tab = base as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }

        return base
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let fileURL: URL
        private let completion: (Result<Bool, Error>) -> Void

        init(
            fileURL: URL,
            completion: @escaping (Result<Bool, Error>) -> Void
        ) {
            self.fileURL = fileURL
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion(.success(true))

            // Keep the temporary source alive while the Files app finishes copying it.
            Task {
                try? await Task.sleep(for: .seconds(30))
                try? FileManager.default.removeItem(at: fileURL)
            }
            SystemFileExporter.activeCoordinator = nil
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            try? FileManager.default.removeItem(at: fileURL)
            completion(.success(false))
            SystemFileExporter.activeCoordinator = nil
        }
    }

    enum SystemFileExporterError: LocalizedError {
        case noPresenter

        var errorDescription: String? {
            let language = InterfaceLanguage.current

            switch self {
            case .noPresenter:
                return language.text("export.error.cannotOpenExporter")
            }
        }
    }
}
#endif

#if os(macOS)
import AppKit

@MainActor
enum SystemFileExporter {
    static func save(
        fileURL: URL,
        suggestedFilename: String,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { response in
            guard response == .OK, let destination = panel.url else {
                try? FileManager.default.removeItem(at: fileURL)
                completion(.success(false))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: fileURL, to: destination)
                try? FileManager.default.removeItem(at: fileURL)
                completion(.success(true))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
#endif
