import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let meetingSRT = UTType(
        exportedAs: "com.voiceminutes.srt",
        conformingTo: .plainText
    )
    static let meetingMarkdown = UTType(
        exportedAs: "com.voiceminutes.markdown",
        conformingTo: .plainText
    )
}

/// The document formats supported by the meeting detail screen.
enum MeetingExportKind: String, CaseIterable, Identifiable {
    case markdown
    case srt
    case pdf

    var id: Self { self }

    var title: String {
        let language = InterfaceLanguage.current

        switch self {
        case .markdown:
            return language.text("export.markdown")
        case .srt:
            return language.text("export.srt")
        case .pdf:
            return language.text("export.pdf")
        }
    }

    var systemImage: String {
        switch self {
        case .markdown:
            return "doc.text"
        case .srt:
            return "captions.bubble"
        case .pdf:
            return "doc.richtext"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown:
            return .meetingMarkdown
        case .srt:
            return .meetingSRT
        case .pdf:
            return .pdf
        }
    }

    func filename(for title: String) -> String {
        let language = InterfaceLanguage.current

        switch self {
        case .markdown:
            return language.format("export.filenameMinutes", title, "md")
        case .srt:
            return language.format("export.filenameTranscript", title, "srt")
        case .pdf:
            return language.format("export.filenameMinutes", title, "pdf")
        }
    }
}

struct MeetingExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.meetingSRT, .meetingMarkdown, .pdf]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
