import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MarkdownConverterView: View {
    @State private var selectedFile: PickedDocument?
    @State private var markdown = ""
    @State private var errorMessage: String?
    @State private var isConverting = false
    @State private var isPickerPresented = false
    @State private var isSharePresented = false
    @State private var isSavePresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Selected File")
                        .font(.headline)

                    Text(selectedFile?.filename ?? "No file selected")
                        .font(.callout)
                        .foregroundStyle(selectedFile == nil ? .secondary : .primary)
                        .lineLimit(2)

                    HStack {
                        Button {
                            isPickerPresented = true
                        } label: {
                            Label("Choose File", systemImage: "doc.badge.plus")
                        }

                        Button {
                            Task { await convertSelectedFile() }
                        } label: {
                            Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(selectedFile == nil || isConverting)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if isConverting {
                    ProgressView("Converting...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                markdownPreview

                actionBar
            }
            .padding()
            .navigationTitle("Markdown Converter")
            .sheet(isPresented: $isPickerPresented) {
                DocumentPicker { document in
                    selectedFile = document
                    errorMessage = nil
                }
            }
            .sheet(isPresented: $isSharePresented) {
                ShareSheet(items: [markdown])
            }
            .fileExporter(
                isPresented: $isSavePresented,
                document: MarkdownFile(text: markdown),
                contentType: UTType(filenameExtension: "md") ?? .plainText,
                defaultFilename: outputFilename
            ) { result in
                if case .failure(let error) = result {
                    errorMessage = "Could not save Markdown: \(error.localizedDescription)"
                }
            }
        }
    }

    private var markdownPreview: some View {
        ScrollView {
            Text(markdown.isEmpty ? "Markdown preview will appear here." : markdown)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(markdown.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = markdown
            }
            .disabled(markdown.isEmpty)

            Button("Share", systemImage: "square.and.arrow.up") {
                isSharePresented = true
            }
            .disabled(markdown.isEmpty)

            Button("Save", systemImage: "square.and.arrow.down") {
                isSavePresented = true
            }
            .disabled(markdown.isEmpty)

            Spacer()

            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await convertSelectedFile() }
            }
            .disabled(selectedFile == nil || isConverting)

            Button("Clear", systemImage: "xmark.circle") {
                selectedFile = nil
                markdown = ""
                errorMessage = nil
            }
        }
        .buttonStyle(.bordered)
    }

    private var outputFilename: String {
        let stem = selectedFile.map { URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent }
        return (stem?.isEmpty == false ? stem! : "converted") + ".md"
    }

    private func convertSelectedFile() async {
        guard let selectedFile else { return }
        isConverting = true
        errorMessage = nil
        defer { isConverting = false }

        do {
            let response = try await MarkdownConverterAPI.convert(file: selectedFile)
            markdown = response.markdown
        } catch let error as MarkdownConverterAPIError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Could not reach CloudBox. Check Tailscale and try again."
        }
    }
}

private struct PickedDocument: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
}

private struct MarkdownConversionResponse: Decodable {
    let filename: String
    let `extension`: String
    let markdown: String
    let conversionMode: String

    private enum CodingKeys: String, CodingKey {
        case filename
        case `extension`
        case markdown
        case conversionMode = "conversion_mode"
    }
}

private enum MarkdownConverterAPIError: Error {
    case backendOffline
    case unsupportedFile
    case tooLarge
    case conversionFailed

    var friendlyMessage: String {
        switch self {
        case .backendOffline:
            return "CloudBox is offline. Check Tailscale and try again."
        case .unsupportedFile:
            return "This file type is not supported."
        case .tooLarge:
            return "This file is too large. Maximum size is 25 MB."
        case .conversionFailed:
            return "CloudBox could not convert this file."
        }
    }
}

private enum MarkdownConverterAPI {
    static func convert(file: PickedDocument) async throws -> MarkdownConversionResponse {
        guard let url = URL(string: "\(CompletedFilesAPI.baseURL)/api/convert-markdown") else {
            throw MarkdownConverterAPIError.backendOffline
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(for: file, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarkdownConverterAPIError.backendOffline
        }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(MarkdownConversionResponse.self, from: data)
        case 400:
            throw MarkdownConverterAPIError.unsupportedFile
        case 413:
            throw MarkdownConverterAPIError.tooLarge
        case 422, 504:
            throw MarkdownConverterAPIError.conversionFailed
        default:
            throw MarkdownConverterAPIError.backendOffline
        }
    }

    private static func multipartBody(for file: PickedDocument, boundary: String) throws -> Data {
        var body = Data()
        let filename = file.filename
        let contentType = UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(try Data(contentsOf: file.url))
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }
}

private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (PickedDocument) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    private var supportedTypes: [UTType] {
        ["pdf", "docx", "pptx", "xlsx", "xls", "csv", "json", "xml", "html", "htm", "txt", "text", "md", "markdown", "epub"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (PickedDocument) -> Void

        init(onPick: @escaping (PickedDocument) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(PickedDocument(url: url, filename: url.lastPathComponent))
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct MarkdownFile: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "md") ?? .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

#Preview {
    MarkdownConverterView()
}
