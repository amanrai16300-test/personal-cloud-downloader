import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let markdownUploadMaxBytes = 25 * 1024 * 1024
private let markdownPhotoMaxPixelDimension = 3_000
private let markdownPhotoJPEGQuality: CGFloat = 0.85

struct MarkdownConverterView: View {
    @State private var selectedFile: PickedDocument?
    @State private var markdown = ""
    @State private var errorMessage: String?
    @State private var emptyResultMessage: String?
    @State private var urlText = ""
    @State private var convertedURL: String?
    @State private var retrySnapshot: MarkdownRetrySnapshot?
    @State private var isConverting = false
    @State private var conversionGeneration = 0
    @State private var isPickerPresented = false
    @State private var isSharePresented = false
    @State private var isSavePresented = false
    @FocusState private var isURLFocused: Bool

    // Palette mirrored from the Home redesign tokens.
    private let screenBackground = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let surface = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let surfaceRaised = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let inputWell = Color(red: 0.022, green: 0.05, blue: 0.105)
    private let hairline = Color.white.opacity(0.08)
    private let mutedText = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)

    var body: some View {
        NavigationStack {
            ZStack {
                ZStack {
                    screenBackground.ignoresSafeArea()
                    RadialGradient(
                        colors: [premiumBlue.opacity(0.12), .clear],
                        center: .init(x: 0.9, y: -0.05),
                        startRadius: 10,
                        endRadius: 380
                    )
                    .ignoresSafeArea()
                }
                .onTapGesture {
                    dismissKeyboard()
                }

                VStack(spacing: 12) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            sourcePanel
                            statusLine
                            markdownPreview
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)

                    actionBar
                        .padding(.horizontal, 16)
                        // The floating CloudBox tab bar lives in the TabView's bottom
                        // safeAreaInset, but pushed navigation destinations don't inherit
                        // that inset, so this screen must clear the bar's height (~74pt)
                        // itself. While the URL field has focus the keyboard covers the
                        // tab bar and provides its own inset, so the plain 12pt gap applies.
                        .padding(.bottom, isURLFocused ? 12 : 86)
                }
            }
            .navigationTitle("Markdown Converter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
            }
            .sheet(isPresented: $isPickerPresented) {
                DocumentPicker { document in
                    selectedFile = document
                    retrySnapshot = nil
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DOCUMENT WORKBENCH")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(premiumBlue)

            Text("CloudBox Convert")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)

            Text("File, photo, or webpage into clean Markdown.")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(mutedText)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture {
            dismissKeyboard()
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("SOURCE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(premiumBlue)

                Spacer()

                Text(sourceCaption)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isConverting ? premiumBlue : mutedText)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }

            HStack(spacing: 10) {
                Button {
                    dismissKeyboard()
                    isPickerPresented = true
                } label: {
                    Label("File", systemImage: "doc.badge.plus")
                }
                .buttonStyle(ConverterPillStyle(tint: premiumBlue, isProminent: true))

                if #available(iOS 16.0, *) {
                    PhotoPickerButton(
                        isDisabled: isConverting,
                        onPickStart: beginPhotoConversion
                    ) { result, generation in
                        await loadSelectedPhoto(result, generation: generation)
                    }
                    .buttonStyle(ConverterPillStyle(tint: premiumBlue, isProminent: false))
                }

                Button {
                    dismissKeyboard()
                    Task { await convertSelectedFile() }
                } label: {
                    Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(ConverterPillStyle(tint: premiumBlue, isProminent: selectedFile != nil))
                .disabled(selectedFile == nil || isConverting)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.86)

            if let selectedFile {
                Label(selectedFile.filename, systemImage: "paperclip")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(premiumBlue)

                    TextField("https://example.com/page", text: $urlText)
                        .focused($isURLFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .tint(premiumBlue)
                        .onSubmit {
                            Task { await convertURL() }
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(inputWell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isURLFocused ? premiumBlue.opacity(0.7) : hairline, lineWidth: 1)
                }

                Button {
                    Task { await convertURL() }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.headline.weight(.heavy))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(ConverterIconButtonStyle(tint: premiumBlue))
                .disabled(trimmedURL.isEmpty || isConverting)
                .accessibilityLabel("Convert URL")
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(surface)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.40), hairline],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 1
                )
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isConverting {
                Label("Converting...", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(premiumBlue)
                    .accessibilityLabel("Status: Converting")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.26))
                    .accessibilityLabel("Error: \(errorMessage)")
            }

            if let emptyResultMessage {
                Label(emptyResultMessage, systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(mutedText)
            }

            if let convertedURL {
                Label(convertedURL, systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(premiumBlue)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var markdownPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PREVIEW")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(premiumBlue)

                Spacer()

                if hasMarkdown {
                    Text("\(markdown.count) chars")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(mutedText)
                }
            }

            ScrollView {
                RenderedMarkdownPreview(markdown: markdown)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
            .background(inputWell, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(hairline, lineWidth: 1)
        }
        .onTapGesture {
            dismissKeyboard()
        }
    }

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
            if hasMarkdown {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = markdown
                }
                .buttonStyle(ConverterActionButtonStyle())

                Button("Share", systemImage: "square.and.arrow.up") {
                    isSharePresented = true
                }
                .buttonStyle(ConverterActionButtonStyle())

                Button("Save", systemImage: "square.and.arrow.down") {
                    isSavePresented = true
                }
                .buttonStyle(ConverterActionButtonStyle())
            }

            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await retryLastConversion() }
            }
            .disabled(retrySnapshot == nil || isConverting)
            .buttonStyle(ConverterActionButtonStyle())

            Button("Clear", systemImage: "xmark.circle") {
                clearAll()
            }
            .buttonStyle(ConverterActionButtonStyle(isDestructive: true))
        }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(surfaceRaised.opacity(0.98), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(hairline, lineWidth: 1)
        }
        .onTapGesture {
            dismissKeyboard()
        }
    }

    private var hasMarkdown: Bool {
        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sourceCaption: String {
        if isConverting {
            return "Working"
        }
        if convertedURL != nil {
            return "URL converted"
        }
        if selectedFile != nil {
            return "File ready"
        }
        if !trimmedURL.isEmpty {
            return "URL ready"
        }
        return "Choose one"
    }

    private var outputFilename: String {
        let stem = selectedFile.map { URL(fileURLWithPath: $0.filename).deletingPathExtension().lastPathComponent } ?? URL(string: convertedURL ?? "")?.host
        return (stem?.isEmpty == false ? stem! : "converted") + ".md"
    }

    private func clearAll() {
        conversionGeneration += 1
        dismissKeyboard()
        isConverting = false
        selectedFile = nil
        urlText = ""
        convertedURL = nil
        retrySnapshot = nil
        markdown = ""
        errorMessage = nil
        emptyResultMessage = nil
    }

    private func dismissKeyboard() {
        isURLFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func showFileConversionError(_ message: String) {
        guard errorMessage != message else { return }
        errorMessage = message
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: "Error: \(message)")
        }
    }

    private func convertSelectedFile(
        file retryFile: PickedDocument? = nil,
        snapshot retrySource: MarkdownRetrySnapshot? = nil
    ) async {
        guard !isConverting, let file = retryFile ?? selectedFile else { return }
        let source = retrySource ?? (
            file.data == nil ? .document(file) : .photo(file)
        )
        conversionGeneration += 1
        let generation = conversionGeneration
        retrySnapshot = source
        isConverting = true
        errorMessage = nil
        emptyResultMessage = nil
        defer {
            if generation == conversionGeneration {
                isConverting = false
            }
        }

        do {
            let response = try await MarkdownConverterAPI.convert(file: file)
            guard generation == conversionGeneration else { return }
            markdown = response.markdown
            convertedURL = nil
        } catch let error as MarkdownConverterAPIError {
            guard generation == conversionGeneration else { return }
            showFileConversionError(error.friendlyMessage)
        } catch {
            guard generation == conversionGeneration else { return }
            showFileConversionError("Could not reach CloudBox. Check Tailscale and try again.")
        }
    }

    private func convertURL(retryURL: String? = nil) async {
        guard !isConverting else { return }
        let url = retryURL ?? trimmedURL
        guard !url.isEmpty else {
            errorMessage = MarkdownConverterAPIError.invalidURL.friendlyMessage
            return
        }

        conversionGeneration += 1
        let generation = conversionGeneration
        dismissKeyboard()
        retrySnapshot = .url(url)
        isConverting = true
        errorMessage = nil
        emptyResultMessage = nil
        convertedURL = nil
        defer {
            if generation == conversionGeneration {
                isConverting = false
            }
        }

        do {
            let response = try await MarkdownConverterAPI.convert(url: url)
            guard generation == conversionGeneration else { return }
            markdown = response.markdown
            convertedURL = response.url
            if !hasMarkdown {
                emptyResultMessage = "Conversion finished, but no Markdown text was extracted from this page."
            }
        } catch let error as MarkdownConverterAPIError {
            guard generation == conversionGeneration else { return }
            errorMessage = error.friendlyMessage
        } catch {
            guard generation == conversionGeneration else { return }
            errorMessage = "Could not reach CloudBox. Check Tailscale and try again."
        }
    }

    private func retryLastConversion() async {
        guard !isConverting, let snapshot = retrySnapshot else { return }
        switch snapshot {
        case .document(let file), .photo(let file):
            await convertSelectedFile(file: file, snapshot: snapshot)
        case .url(let url):
            await convertURL(retryURL: url)
        }
    }

    private func beginPhotoConversion() -> Int? {
        guard !isConverting else { return nil }
        conversionGeneration += 1
        retrySnapshot = nil
        isConverting = true
        errorMessage = nil
        emptyResultMessage = nil
        return conversionGeneration
    }

    private func loadSelectedPhoto(
        _ result: Result<Data, Error>,
        generation: Int
    ) async {
        guard generation == conversionGeneration else { return }
        defer {
            if generation == conversionGeneration {
                isConverting = false
            }
        }

        do {
            let uploadData = try autoreleasepool {
                let data = try result.get()
                guard let source = CGImageSourceCreateWithData(
                    data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                ) else {
                    throw MarkdownConverterAPIError.photoLoadFailed
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: markdownPhotoMaxPixelDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        options as CFDictionary
                    ),
                    let jpeg = UIImage(cgImage: image).jpegData(
                        compressionQuality: markdownPhotoJPEGQuality
                    )
                else {
                    throw MarkdownConverterAPIError.photoLoadFailed
                }
                return jpeg
            }
            guard generation == conversionGeneration else { return }
            guard uploadData.count <= markdownUploadMaxBytes else {
                throw MarkdownConverterAPIError.tooLarge
            }
            selectedFile = PickedDocument(data: uploadData, filename: "photo.jpg", contentType: "image/jpeg")
            markdown = ""
            convertedURL = nil
        } catch let error as MarkdownConverterAPIError {
            guard generation == conversionGeneration else { return }
            showFileConversionError(error.friendlyMessage)
        } catch {
            guard generation == conversionGeneration else { return }
            showFileConversionError(MarkdownConverterAPIError.photoLoadFailed.friendlyMessage)
        }
    }
}

private struct RenderedMarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if markdown.isEmpty {
                Text("Markdown preview will appear here.")
                    .foregroundStyle(Color(red: 0.58, green: 0.68, blue: 0.82))
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
                .foregroundStyle(Color(red: 0.92, green: 0.97, blue: 1.0))
                .padding(.bottom, 2)
        case .heading2:
            inlineText(block.text)
                .font(.title3.bold())
                .foregroundStyle(Color(red: 0.84, green: 0.92, blue: 1.0))
                .padding(.top, 4)
        case .heading3:
            inlineText(block.text)
                .font(.headline)
                .foregroundStyle(Color(red: 0.76, green: 0.86, blue: 1.0))
        case .bullet:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.body.bold())
                    .foregroundStyle(Color(red: 0.42, green: 0.66, blue: 1.0))
                inlineText(block.text)
                    .font(.body)
                    .foregroundStyle(Color(red: 0.82, green: 0.88, blue: 0.96))
                    .lineSpacing(3)
            }
        case .numbered:
            HStack(alignment: .top, spacing: 8) {
                Text(block.marker ?? "")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color(red: 0.50, green: 0.70, blue: 1.0))
                inlineText(block.text)
                    .font(.body)
                    .foregroundStyle(Color(red: 0.82, green: 0.88, blue: 0.96))
                    .lineSpacing(3)
            }
        case .paragraph:
            inlineText(block.text)
                .font(.body)
                .foregroundStyle(Color(red: 0.82, green: 0.88, blue: 0.96))
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
    let onPickStart: () -> Int?
    let onPick: (Result<Data, Error>, Int) async -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images) {
            Label("Photo", systemImage: "photo")
        }
        .disabled(isDisabled)
        .onChange(of: item) { newItem in
            guard let newItem else { return }
            guard let generation = onPickStart() else { return }
            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        throw MarkdownConverterAPIError.photoLoadFailed
                    }
                    await onPick(.success(data), generation)
                } catch {
                    await onPick(.failure(error), generation)
                }
            }
        }
    }
}

private struct ConverterPillStyle: ButtonStyle {
    let tint: Color
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(isProminent ? Color.white : tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isProminent ? tint : tint.opacity(0.14))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isProminent ? Color.white.opacity(0.18) : tint.opacity(0.30), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(!isEnabled ? 0.42 : (configuration.isPressed ? 0.82 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ConverterIconButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(red: 0.95, green: 0.98, blue: 1.0))
            .background(tint, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(red: 0.70, green: 0.82, blue: 1.0).opacity(0.28), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(!isEnabled ? 0.42 : (configuration.isPressed ? 0.82 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ConverterActionButtonStyle: ButtonStyle {
    var isDestructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isDestructive ? Color(red: 0.97, green: 0.55, blue: 0.48) : Color(red: 0.30, green: 0.59, blue: 1.0))
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                (isDestructive ? Color(red: 0.97, green: 0.44, blue: 0.36) : Color(red: 0.30, green: 0.59, blue: 1.0)).opacity(0.13),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        (isDestructive ? Color(red: 0.97, green: 0.44, blue: 0.36) : Color(red: 0.30, green: 0.59, blue: 1.0)).opacity(0.30),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(!isEnabled ? 0.42 : (configuration.isPressed ? 0.78 : 1))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
        self.contentType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    init(data: Data, filename: String, contentType: String) {
        self.url = nil
        self.data = data
        self.filename = filename
        self.contentType = contentType
    }
}

private enum MarkdownRetrySnapshot {
    case document(PickedDocument)
    case photo(PickedDocument)
    case url(String)
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
            guard
                let decoded = try? JSONDecoder().decode(MarkdownConversionResponse.self, from: data),
                !decoded.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MarkdownConverterAPIError.conversionFailed
            }
            return decoded
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
            guard data.count <= markdownUploadMaxBytes else {
                throw MarkdownConverterAPIError.tooLarge
            }
            uploadData = data
        } else if let url = file.url {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw CocoaError(.fileReadUnknown)
            }
            guard fileSize <= markdownUploadMaxBytes else {
                throw MarkdownConverterAPIError.tooLarge
            }
            uploadData = try Data(contentsOf: url)
            guard uploadData.count <= markdownUploadMaxBytes else {
                throw MarkdownConverterAPIError.tooLarge
            }
        } else {
            throw MarkdownConverterAPIError.conversionFailed
        }

        body.reserveCapacity(uploadData.count + 512)
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
