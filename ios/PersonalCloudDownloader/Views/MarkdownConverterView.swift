import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MarkdownConverterView: View {
    @State private var selectedFile: PickedDocument?
    @State private var markdown = ""
    @State private var errorMessage: String?
    @State private var emptyResultMessage: String?
    @State private var urlText = ""
    @State private var convertedURL: String?
    @State private var lastConversion: MarkdownConversionKind?
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

                        if #available(iOS 16.0, *) {
                            PhotoPickerButton(isDisabled: isConverting) { result in
                                await loadSelectedPhoto(result)
                            }
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

                VStack(alignment: .leading, spacing: 12) {
                    Text("Paste URL")
                        .font(.headline)

                    TextField("https://example.com/page", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .onSubmit {
                            Task { await convertURL() }
                        }

                    Button {
                        Task { await convertURL() }
                    } label: {
                        Label("Convert URL", systemImage: "link")
                    }
                    .disabled(trimmedURL.isEmpty || isConverting)
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

                if let emptyResultMessage {
                    Label(emptyResultMessage, systemImage: "doc.text.magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let convertedURL {
                    Text("Converted: \(convertedURL)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
                    emptyResultMessage = nil
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
            RenderedMarkdownPreview(markdown: markdown)
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
            if hasMarkdown {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = markdown
                }

                Button("Share", systemImage: "square.and.arrow.up") {
                    isSharePresented = true
                }

                Button("Save", systemImage: "square.and.arrow.down") {
                    isSavePresented = true
                }
            }

            Spacer()

            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await retryLastConversion() }
            }
            .disabled((lastConversion == nil && selectedFile == nil) || isConverting)

            Button("Clear", systemImage: "xmark.circle") {
                selectedFile = nil
                urlText = ""
                convertedURL = nil
                lastConversion = nil
                markdown = ""
                errorMessage = nil
                emptyResultMessage = nil
            }
        }
        .buttonStyle(.bordered)
    }

    private var hasMarkdown: Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var outputFilename: String {
        let stem = selectedFile.map { URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent } ?? URL(string: convertedURL ?? "")?.host
        return (stem?.isEmpty == false ? stem! : "converted") + ".md"
    }

    private func convertSelectedFile() async {
        guard let selectedFile else { return }
        lastConversion = .file
        isConverting = true
        errorMessage = nil
        emptyResultMessage = nil
        defer { isConverting = false }

        do {
            let response = try await MarkdownConverterAPI.convert(file: selectedFile)
            markdown = response.markdown
            convertedURL = nil
            if !hasMarkdown {
                emptyResultMessage = "Conversion finished, but no Markdown text was extracted from this file. This can happen with scanned PDFs or PDFs with broken text encoding."
            }
        } catch let error as MarkdownConverterAPIError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Could not reach CloudBox. Check Tailscale and try again."
        }
    }

    private func convertURL() async {
        let url = trimmedURL
        guard !url.isEmpty else {
            errorMessage = MarkdownConverterAPIError.invalidURL.friendlyMessage
            return
        }

        lastConversion = .url
        isConverting = true
        errorMessage = nil
        emptyResultMessage = nil
        convertedURL = nil
        defer { isConverting = false }

        do {
            let response = try await MarkdownConverterAPI.convert(url: url)
            markdown = response.markdown
            convertedURL = response.url
            lastConversion = .url
            if !hasMarkdown {
                emptyResultMessage = "Conversion finished, but no Markdown text was extracted from this page."
            }
        } catch let error as MarkdownConverterAPIError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Could not reach CloudBox. Check Tailscale and try again."
        }
    }

    private func retryLastConversion() async {
        switch lastConversion {
        case .file:
            await convertSelectedFile()
        case .url:
            await convertURL()
        case nil:
            await convertSelectedFile()
        }
    }

    private func loadSelectedPhoto(_ result: Result<Data, Error>) async {
        errorMessage = nil
        emptyResultMessage = nil

        do {
            let data = try result.get()
            guard
                let image = UIImage(data: data),
                let uploadData = image.jpegData(compressionQuality: 0.9)
            else {
                throw MarkdownConverterAPIError.photoLoadFailed
            }
            selectedFile = PickedDocument(data: uploadData, filename: "photo.jpg", contentType: "image/jpeg")
            markdown = ""
            convertedURL = nil
            lastConversion = nil
        } catch let error as MarkdownConverterAPIError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = MarkdownConverterAPIError.photoLoadFailed.friendlyMessage
        }
    }
}

private struct RenderedMarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if markdown.isEmpty {
                Text("Markdown preview will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(renderedBlocks) { block in
                    blockView(block)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var renderedBlocks: [MarkdownPreviewBlock] {
        MarkdownPreviewBlock.parse(markdown)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownPreviewBlock) -> some View {
        switch block.kind {
        case .heading1:
            inlineText(block.text)
                .font(.title2.bold())
                .padding(.bottom, 2)
        case .heading2:
            inlineText(block.text)
                .font(.title3.bold())
                .padding(.top, 4)
        case .heading3:
            inlineText(block.text)
                .font(.headline)
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.body.bold())
                inlineText(block.text)
                    .font(.body)
                    .lineSpacing(3)
            }
        case .numbered:
            HStack(alignment: .top, spacing: 8) {
                Text(block.marker ?? "")
                    .font(.body.monospacedDigit())
                inlineText(block.text)
                    .font(.body)
                    .lineSpacing(3)
            }
        case .paragraph:
            inlineText(block.text)
                .font(.body)
                .lineSpacing(4)
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private struct MarkdownPreviewBlock: Identifiable {
    enum Kind {
        case heading1
        case heading2
        case heading3
        case bullet
        case numbered
        case paragraph
    }

    let id: Int
    let kind: Kind
    let text: String
    let marker: String?

    static func parse(_ markdown: String) -> [MarkdownPreviewBlock] {
        var blocks: [MarkdownPreviewBlock] = []
        var paragraph: [String] = []

        func append(_ kind: Kind, _ text: String, marker: String? = nil) {
            blocks.append(MarkdownPreviewBlock(id: blocks.count, kind: kind, text: text, marker: marker))
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph, paragraph.joined(separator: " "))
            paragraph.removeAll()
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flushParagraph()
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                append(.heading3, String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                append(.heading2, String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                append(.heading1, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if let bullet = bulletText(from: line) {
                flushParagraph()
                append(.bullet, bullet)
            } else if let numbered = numberedText(from: line) {
                flushParagraph()
                append(.numbered, numbered.text, marker: numbered.marker)
            } else {
                paragraph.append(line)
            }
        }

        flushParagraph()
        return blocks
    }

    private static func bulletText(from line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func numberedText(from line: String) -> (marker: String, text: String)? {
        guard let match = line.range(of: #"^\d+[\.)]\s+"#, options: .regularExpression) else { return nil }
        let marker = String(line[match]).trimmingCharacters(in: .whitespaces)
        let text = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (marker, text)
    }
}

@available(iOS 16.0, *)
private struct PhotoPickerButton: View {
    let isDisabled: Bool
    let onPick: (Result<Data, Error>) async -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label("Select Photo", systemImage: "photo")
        }
        .disabled(isDisabled)
        .onChange(of: item) { newItem in
            guard let newItem else { return }
            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        throw MarkdownConverterAPIError.photoLoadFailed
                    }
                    await onPick(.success(data))
                } catch {
                    await onPick(.failure(error))
                }
            }
        }
    }
}

private struct PickedDocument: Identifiable {
    let id = UUID()
    let url: URL?
    let data: Data?
    let filename: String
    let contentType: String?

    init(url: URL, filename: String) {
        self.url = url
        self.data = nil
        self.filename = filename
        self.contentType = nil
    }

    init(data: Data, filename: String, contentType: String) {
        self.url = nil
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

private enum MarkdownConversionKind {
    case file
    case url
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

private struct MarkdownURLConversionResponse: Decodable {
    let url: String
    let markdown: String
    let conversionMode: String

    private enum CodingKeys: String, CodingKey {
        case url
        case markdown
        case conversionMode = "conversion_mode"
    }
}

private struct MarkdownConverterErrorResponse: Decodable {
    let detail: String?
}

private enum MarkdownConverterAPIError: Error {
    case backendOffline
    case unsupportedFile
    case invalidURL
    case privateURL
    case urlTimeout
    case unreachableURL
    case unsupportedURLContent
    case tooLarge
    case urlTooLarge
    case conversionFailed
    case urlConversionFailed
    case photoLoadFailed

    var friendlyMessage: String {
        switch self {
        case .backendOffline:
            return "CloudBox is offline. Check Tailscale and try again."
        case .unsupportedFile:
            return "This file type is not supported."
        case .invalidURL:
            return "Enter a valid http:// or https:// webpage URL."
        case .privateURL:
            return "Private, local, or internal URLs are not allowed."
        case .urlTimeout:
            return "The webpage took too long to respond. Try again later."
        case .unreachableURL:
            return "CloudBox could not reach that webpage."
        case .unsupportedURLContent:
            return "This URL is not a supported webpage."
        case .tooLarge:
            return "This file is too large. Maximum size is 25 MB."
        case .urlTooLarge:
            return "This webpage is too large to convert."
        case .conversionFailed:
            return "CloudBox could not convert this file."
        case .urlConversionFailed:
            return "CloudBox could not convert this webpage."
        case .photoLoadFailed:
            return "Could not load this photo. Choose another photo and try again."
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

    static func convert(url rawURL: String) async throws -> MarkdownURLConversionResponse {
        guard isValidWebURL(rawURL) else {
            throw MarkdownConverterAPIError.invalidURL
        }
        guard let endpoint = URL(string: "\(CompletedFilesAPI.baseURL)/api/convert-markdown-url") else {
            throw MarkdownConverterAPIError.backendOffline
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": rawURL])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MarkdownConverterAPIError.backendOffline
        }

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(MarkdownURLConversionResponse.self, from: data)
        case 400:
            throw urlBadRequestError(from: data)
        case 413:
            throw MarkdownConverterAPIError.urlTooLarge
        case 415:
            throw MarkdownConverterAPIError.unsupportedURLContent
        case 422:
            throw MarkdownConverterAPIError.urlConversionFailed
        case 504:
            throw MarkdownConverterAPIError.urlTimeout
        case 502:
            throw MarkdownConverterAPIError.unreachableURL
        default:
            throw MarkdownConverterAPIError.backendOffline
        }
    }

    private static func isValidWebURL(_ rawURL: String) -> Bool {
        guard
            let components = URLComponents(string: rawURL),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.isEmpty == false
        else {
            return false
        }
        return true
    }

    private static func urlBadRequestError(from data: Data) -> MarkdownConverterAPIError {
        let detail = (try? JSONDecoder().decode(MarkdownConverterErrorResponse.self, from: data).detail)?.lowercased() ?? ""
        if detail.contains("private") || detail.contains("internal") || detail.contains("local") {
            return .privateURL
        }
        if detail.contains("resolved") {
            return .unreachableURL
        }
        return .invalidURL
    }

    private static func multipartBody(for file: PickedDocument, boundary: String) throws -> Data {
        var body = Data()
        let filename = file.filename
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        let contentType = file.contentType ?? UTType(filenameExtension: fileExtension)?.preferredMIMEType ?? "application/octet-stream"
        let uploadData: Data
        if let data = file.data {
            uploadData = data
        } else if let url = file.url {
            uploadData = try Data(contentsOf: url)
        } else {
            throw MarkdownConverterAPIError.conversionFailed
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(uploadData)
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
