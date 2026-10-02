import SwiftUI

struct StudyToolsSheet: View {
    let documentID: UUID
    let store: NotyStore
    var selectedText: String?
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var reviewIDs: [UUID] = []
    @State private var reviewIndex = 0
    @State private var isAnswerVisible = false
    @State private var isReviewing = false
    @State private var knownCount = 0
    @State private var duration = 25
    @State private var remaining: TimeInterval = 25 * 60
    @State private var endsAt: Date?
    @State private var isFinished = false
    @AppStorage("noty.study.focusEndsAt") private var savedEnd = 0.0
    @AppStorage("noty.study.focusRemaining") private var savedRemaining = 1500.0
    @AppStorage("noty.study.focusDuration") private var savedDuration = 25

    private var cards: [NotyStudyCard] { store.documents.first(where: { $0.id == documentID })?.studyCards ?? [] }
    private var reviewCard: NotyStudyCard? {
        guard reviewIDs.indices.contains(reviewIndex) else { return nil }
        return cards.first(where: { $0.id == reviewIDs[reviewIndex] })
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    focusPanel
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Study cards", systemImage: "rectangle.on.rectangle").font(.headline)
                            Spacer()
                            if !cards.isEmpty {
                                Button("Review") { startReview() }.buttonStyle(.borderedProminent)
                            }
                        }
                        Text("Turn a definition, formula, or tricky concept into a question you can practise.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        TextField("Question", text: $question, axis: .vertical).lineLimit(2...4)
                            .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        TextField("Answer", text: $answer, axis: .vertical).lineLimit(3...8)
                            .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                        Button("Add study card", systemImage: "plus") {
                            let card = NotyStudyCard(question: question.trimmingCharacters(in: .whitespacesAndNewlines), answer: answer.trimmingCharacters(in: .whitespacesAndNewlines))
                            store.updateStudyCards(documentID: documentID, cards: cards + [card])
                            question = ""; answer = ""
                        }.buttonStyle(.borderedProminent)
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ForEach(cards) { card in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(card.question).font(.subheadline.weight(.semibold))
                                    Text(card.answer).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Spacer()
                                Button(role: .destructive) { store.updateStudyCards(documentID: documentID, cards: cards.filter { $0.id != card.id }) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete study card")
                            }.padding(.vertical, 8)
                        }
                    }.padding(20).frostedPanel()
                }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }.background { FrostedWorkspaceBackground() }
                .navigationTitle("Study space").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear {
                    if let selectedText, !selectedText.isEmpty { answer = selectedText }
                    duration = savedDuration; remaining = savedRemaining
                    if savedEnd > 0 { endsAt = Date(timeIntervalSince1970: savedEnd) }
                }
                .sheet(isPresented: $isReviewing) { review }
        }
    }
    private var focusPanel: some View {
        VStack(spacing: 16) {
            Label(isFinished ? "Session complete" : "Focus timer", systemImage: isFinished ? "checkmark.circle" : "timer").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(ceil(endsAt.map { $0.timeIntervalSince(context.date) } ?? remaining)))
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .onChange(of: seconds) { _, value in if value == 0 && endsAt != nil { endsAt = nil; savedEnd = 0; remaining = 0; savedRemaining = 0; isFinished = true } }
            }
            if endsAt == nil {
                Picker("Focus length", selection: $duration) {
                    Text("15 min").tag(15); Text("25 min").tag(25); Text("45 min").tag(45)
                }.pickerStyle(.segmented).onChange(of: duration) { _, value in remaining = TimeInterval(value * 60); savedRemaining = remaining; savedDuration = value; isFinished = false }
            }
            HStack(spacing: 16) {
                Button(endsAt == nil ? "Start focus" : "Pause", systemImage: endsAt == nil ? "play.fill" : "pause.fill") {
                    if let endsAt { remaining = max(0, endsAt.timeIntervalSinceNow); savedRemaining = remaining; self.endsAt = nil; savedEnd = 0 }
                    else { if remaining <= 0 { remaining = TimeInterval(duration * 60) }; endsAt = Date().addingTimeInterval(remaining); savedEnd = endsAt!.timeIntervalSince1970; isFinished = false }
                }.buttonStyle(.borderedProminent)
                Button("Reset") { endsAt = nil; savedEnd = 0; remaining = TimeInterval(duration * 60); savedRemaining = remaining; isFinished = false }.buttonStyle(.bordered)
            }
            Text("A little space to concentrate. Your timer keeps time while you write.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(maxWidth: .infinity).frostedPanel()
    }
    private func startReview() { reviewIDs = cards.map(\.id).shuffled(); reviewIndex = 0; knownCount = 0; isAnswerVisible = false; isReviewing = true }
    private var review: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let card = reviewCard {
                    Text("\(reviewIndex + 1) of \(reviewIDs.count)").font(.subheadline).foregroundStyle(.secondary)
                    Text(card.question).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    Spacer()
                    if isAnswerVisible {
                        Text(card.answer).font(.title3).multilineTextAlignment(.center).textSelection(.enabled)
                        HStack {
                            Button("Keep practising") { nextCard(known: false) }.buttonStyle(.bordered)
                            Button("Got it") { nextCard(known: true) }.buttonStyle(.borderedProminent)
                        }
                    } else { Button("Reveal answer") { isAnswerVisible = true }.buttonStyle(.borderedProminent) }
                    Spacer()
                } else {
                    Image(systemName: "checkmark.seal").font(.system(size: 54, weight: .light)).foregroundStyle(.teal)
                    Text("Review complete").font(.title2.weight(.semibold))
                    Text("You knew \(knownCount) of \(reviewIDs.count) cards.").foregroundStyle(.secondary)
                    Button("Review again") { startReview() }.buttonStyle(.borderedProminent)
                }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background { FrostedWorkspaceBackground() }
                .navigationTitle("Review cards").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isReviewing = false } } }
        }
    }
    private func nextCard(known: Bool) { if known { knownCount += 1 }; reviewIndex += 1; isAnswerVisible = false }
}
