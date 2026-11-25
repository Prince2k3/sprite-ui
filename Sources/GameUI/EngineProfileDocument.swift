import ECSCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Immutable JSON bytes keep file-export work independent of the live profiler.
struct EngineProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(capture: EngineProfileCapture) throws {
        data = try capture.jsonData(prettyPrinted: true)
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
