// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sajal Maity

import SwiftUI

/// Natural-language Q&A over the user's spending, powered by Apple Intelligence.
/// Presented as a sheet from the Insights tab.
struct AskAIView: View {
    @EnvironmentObject var store: TransactionStore
    @Environment(\.dismiss) private var dismiss

    // Owned by the view so SwiftUI keeps the SAME instance — and its single
    // LanguageModelSession — alive across re-renders. A plain `let` would be
    // discarded whenever the view struct is recreated, dropping the conversation
    // context and forcing every follow-up to start from scratch.
    @State private var service = AIQueryService()

    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var isThinking = false

    private let suggestions = [
        "How much did I spend this month?",
        "What are my biggest categories?",
        "Which subscriptions am I paying for?",
        "Where can I cut back?",
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty { intro }
                            ForEach(messages) { ChatBubble(message: $0) }
                            if isThinking {
                                ChatBubble(message: ChatMessage(role: .assistant, text: "…", thinking: true))
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: isThinking) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }

                if messages.isEmpty {
                    suggestionChips
                }

                inputBar
            }
            .navigationTitle("Ask about your spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { service.startConversation(with: store.visibleExpenses) }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Apple Intelligence", systemImage: "sparkles")
                .font(.caption.bold()).foregroundStyle(Brand.ai)
            Text("Ask anything about your spending — it's answered on-device from your own data. Nothing leaves your phone.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Brand.ai.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s).font(.caption)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Brand.ai.opacity(0.12), in: Capsule())
                            .foregroundStyle(Brand.ai)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal).padding(.bottom, 8)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask a question…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .onSubmit { send(input) }
            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? Brand.ai : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: q))
        isThinking = true
        Task {
            let answer = await service.ask(q)
            isThinking = false
            messages.append(ChatMessage(role: .assistant,
                                        text: answer ?? "Sorry — I couldn't answer that just now."))
        }
    }
}

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
    var thinking = false
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if message.thinking {
                    ProgressView().padding(.vertical, 4)
                } else {
                    Text(message.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(message.role == .user ? .white : .primary)
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: AnyShapeStyle {
        message.role == .user
            ? AnyShapeStyle(Brand.ai)
            : AnyShapeStyle(.quaternary.opacity(0.5))
    }
}
