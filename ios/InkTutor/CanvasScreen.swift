import SwiftUI
import PDFKit

/// App entry screen: the student's worksheet canvas, full-screen, plus the
/// tutor's popup page. Opens directly onto the canvas — no landing screen
/// (demo priority).
struct CanvasScreen: View {
    /// Page size in canvas points, origin top-left (Global Constraints).
    static let pageSize = CGSize(width: 768, height: 1024)

    @StateObject private var studentPage = PageModel(role: .student)
    @StateObject private var tutorPage = PageModel(role: .tutor)
    @State private var showTutorPage = false

    /// One shared realtime session for the whole screen — the voice bar
    /// drives it, and the student canvas pushes snapshots into it.
    private let session: TutorSession = RealtimeSession()

    var body: some View {
        ZStack {
            PageCanvasRepresentable(page: studentPage, pageSize: Self.pageSize, session: session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    VoiceBarView(session: session)
                }
                Spacer()
            }
            .padding()

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    // TEMP: manual trigger for the tutor popup, standing in for the
                    // [NEWPAGE] tag until the streaming tag parser (Task 8) drives it.
                    Button("Example") { showTutorPage = true }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
            }

            if showTutorPage {
                TutorPagePopup(page: tutorPage, pageSize: Self.pageSize, isPresented: $showTutorPage)
            }
        }
        // PDF underlay disabled for now (Hugh, 2026-07-12): blank canvas, tutor
        // reads the ink alone. Re-enable by restoring this call.
        // .onAppear(perform: loadAssignmentPDF)
    }

    /// Renders page 1 of the bundled worksheet into `studentPage.pdfImage`.
    /// Student page only — the tutor page never has a PDF underlay.
    private func loadAssignmentPDF() {
        guard studentPage.pdfImage == nil,
              // Real middle-school worksheet (Mashup Math, tutoring use permitted) —
              // swapped in over the generated assignment.pdf, which stays bundled as backup.
              let url = Bundle.main.url(forResource: "worksheet-equations-word-problems", withExtension: "pdf"),
              let document = PDFDocument(url: url),
              let pdfPage = document.page(at: 0) else { return }
        let thumbnailSize = CGSize(width: Self.pageSize.width * 2, height: Self.pageSize.height * 2)
        studentPage.pdfImage = pdfPage.thumbnail(of: thumbnailSize, for: .mediaBox)
    }
}

/// The tutor's page as a popup card over a dimmed scrim (Hugh, 2026-07-13:
/// don't take the student away from their work). Closeable anytime; the
/// PageModel survives dismissal so reopening restores the drawing.
private struct TutorPagePopup: View {
    @ObservedObject var page: PageModel
    let pageSize: CGSize
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            GeometryReader { geo in
                let cardWidth = geo.size.width * 0.85
                let cardHeight = geo.size.height * 0.85

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            isPresented = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                    .background(.white)

                    PageCanvasRepresentable(page: page, pageSize: pageSize)
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 20)
                .frame(width: cardWidth, height: cardHeight)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .transition(.opacity)
    }
}

#Preview {
    CanvasScreen()
}
