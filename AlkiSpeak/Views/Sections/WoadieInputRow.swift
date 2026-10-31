import AppKit
import SwiftUI

struct WoadieInputRow: View {
    var model: AppModel
    /// Kept while the Expression menu has focus, so a tag lands at the cursor.
    @State private var selection: TextSelection?
    @State private var showingWebPage = false
    @State private var webAddress = ""

    var body: some View {
        AlkiGlassSurface {
            VStack(alignment: .leading, spacing: 12) {
                if let book = model.store.book {
                    BookBar(model: model, book: book)
                    Divider().opacity(0.4)
                }
                WoadieTextEditor(
                    text: Binding(
                        get: { model.inputText },
                        set: { model.inputText = $0 }
                    ),
                    selection: $selection,
                    placeholder: "What should AlkiSpeak say?",
                    isDisabled: !model.canEditText
                )

                if let speakers = model.selectedDialogueSpeakers {
                    Text("DIALOGUE: START EACH LINE WITH " + speakers.map { "\($0.name.uppercased()):" }.joined(separator: " OR ")
                         + " · ADD A NOTE LIKE \(speakers[0].name.uppercased()) (CHEERFUL):")
                        .font(WoadieTheme.mono(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                }
                HStack {
                    Text("COMMAND RETURN TO SEND")
                        .font(WoadieTheme.mono(size: 9, weight: .medium))
                        .tracking(0.4)
                        .foregroundStyle(WoadieTheme.foregroundSubtle)
                    Spacer()
                    if model.isImporting {
                        ProgressView().controlSize(.small)
                    }
                    WoadieButton(title: "Open…", systemImage: "doc", variant: .ghost) {
                        model.openDocument()
                    }
                    .help("Read a PDF, EPUB, Word, RTF, HTML, Markdown or text file (⌘O). You can also drop files here.")
                    WoadieButton(title: "Web Page…", systemImage: "globe", variant: .ghost) {
                        // Start from a copied link, if there is one.
                        let copied = NSPasteboard.general.string(forType: .string) ?? ""
                        webAddress = DocumentImporter.webURL(in: copied)?.absoluteString ?? ""
                        showingWebPage = true
                    }
                    .help("Read the main article of a web page")
                    .popover(isPresented: $showingWebPage, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Read a web page")
                                .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                            TextField("https://…", text: $webAddress)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 320)
                                .onSubmit(loadWebPage)
                            HStack {
                                Spacer()
                                WoadieButton(title: "Load", systemImage: "arrow.down.doc", variant: .primary, action: loadWebPage)
                                    .disabled(DocumentImporter.webURL(in: webAddress) == nil)
                            }
                        }
                        .padding(16)
                    }
                    if !model.selectedVoiceExpressionTags.isEmpty {
                        Menu {
                            ForEach(model.selectedVoiceExpressionTags, id: \.self) { tag in
                                Button("[\(tag)]") { insert(tag) }
                            }
                        } label: {
                            Label("Expression", systemImage: "face.smiling")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Insert a cue like [Laughter] that this voice performs")
                    }
                    if model.showAddToLog {
                        WoadieButton(
                            title: "Add to Log",
                            systemImage: "plus",
                            variant: .default
                        ) {
                            model.addCurrentToLog()
                        }
                    }
                    WoadieButton(
                        title: "Generate Speech",
                        systemImage: "waveform",
                        variant: .primary
                    ) {
                        model.speak()
                    }
                    .disabled(!model.canSpeak)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .padding(15)
        }
    }

    private func loadWebPage() {
        guard let url = DocumentImporter.webURL(in: webAddress) else { return }
        showingWebPage = false
        model.importWebPage(url)
    }

    private func insert(_ tag: String) {
        let range = selection?.characterRange(in: model.inputText)
        let cursor = model.insertExpressionTag(tag, replacing: range)
        let text = model.inputText
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: min(cursor, text.count)))
    }
}

/// Chapters, listening, rendering, export and the sleep timer for an open book.
private struct BookBar: View {
    var model: AppModel
    let book: Book

    private var chapterIndex: Int { model.store.bookChapter }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(WoadieTheme.foregroundSubtle)
            Text(book.title)
                .font(WoadieTheme.rounded(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
                .help(book.title)

            Button { model.selectChapter(chapterIndex - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .disabled(chapterIndex == 0)
                .help("Previous chapter")
            Menu {
                ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        model.selectChapter(index)
                    } label: {
                        if index == chapterIndex {
                            Label("\(index + 1). \(chapter.title)", systemImage: "checkmark")
                        } else {
                            Text("\(index + 1). \(chapter.title)")
                        }
                    }
                }
            } label: {
                Text("Chapter \(chapterIndex + 1) of \(book.chapters.count)")
                    .font(WoadieTheme.mono(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(model.currentChapter?.title ?? "")
            Button { model.selectChapter(chapterIndex + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(chapterIndex >= book.chapters.count - 1)
                .help("Next chapter")

            Spacer(minLength: 8)

            if let render = model.store.bookRender, render.isRunning || render.message != nil {
                renderStatus(render)
            }

            let canResume = model.bookProgress.map { $0.chapter == chapterIndex && $0.offset > 0 } ?? false
            WoadieButton(title: canResume ? "Resume" : "Listen", systemImage: "play.fill", variant: .primary) {
                model.listenToChapter(resume: canResume)
            }
            .help(canResume ? "Continue this chapter where you left off" : "Play this chapter, then the next ones")

            Menu {
                Button("Render Whole Book") { model.renderBook() }
                Button("Export Audiobook (.m4b)…") { model.exportBook(.m4b) }
                Button("Export Chapter Files (MP3)…") { model.exportBook(.chapterFiles) }
                Divider()
                Button("Close Book") { model.closeBook() }
            } label: {
                Label("Audiobook", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Render the whole book ahead, or export it as an audiobook")

            sleepTimerMenu
        }
        .font(WoadieTheme.rounded(size: 12, weight: .medium))
    }

    @ViewBuilder
    private func renderStatus(_ render: BookRenderState) -> some View {
        HStack(spacing: 6) {
            if render.isRunning {
                ProgressView(value: render.fraction)
                    .frame(width: 80)
                Text(render.message ?? "Rendering \(Int(render.fraction * 100))%")
                    .font(WoadieTheme.mono(size: 9, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .lineLimit(1)
                    .fixedSize()
                Button { model.pauseBookRender() } label: { Image(systemName: "pause.circle") }
                    .buttonStyle(.plain)
                    .help("Pause rendering; it picks up where it left off")
            } else if let message = render.message {
                Text(message)
                    .font(WoadieTheme.mono(size: 9, weight: .medium))
                    .foregroundStyle(WoadieTheme.foregroundSubtle)
                    .lineLimit(1)
            }
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            Button("Off") { model.setSleepTimer(.off) }
            Button("End of Chapter") { model.setSleepTimer(.endOfChapter) }
            ForEach([15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) Minutes") { model.setSleepTimer(.at(Date().addingTimeInterval(Double(minutes) * 60))) }
            }
        } label: {
            switch model.store.sleepTimer {
            case .off:
                Image(systemName: "moon.zzz")
            case .endOfChapter:
                Label("Chapter end", systemImage: "moon.zzz.fill")
            case .at(let date):
                Label {
                    Text(date, style: .timer)
                } icon: {
                    Image(systemName: "moon.zzz.fill")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sleep timer")
    }
}
