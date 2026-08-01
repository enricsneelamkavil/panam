//
//  FinanceChatView.swift
//  Panam
//

import SwiftUI
import SwiftData

struct FinanceChatView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var isThinking = false
    @State private var chatSession: FinanceChatSession?

    private var canSend: Bool {
        !isThinking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if messages.isEmpty {
                                Text("Ask about your money — \u{201C}How much did I spend on fuel this month?\u{201D}, \u{201C}What's due this week?\u{201D}, \u{201C}How much does Ramesh owe me?\u{201D}")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 48)
                                    .padding(.horizontal, 24)
                            }

                            ForEach(messages) { message in
                                MessageBubble(message: message)
                            }

                            if isThinking {
                                HStack {
                                    ProgressView()
                                    Spacer()
                                }
                                .id("thinking")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) {
                        withAnimation {
                            proxy.scrollTo(messages.last?.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: isThinking) {
                        if isThinking {
                            withAnimation {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    TextField("Ask about your money…", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .onSubmit(send)

                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(!canSend)
                }
                .padding()
            }
            .navigationTitle("Ask Panam")
        }
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        isThinking = true

        Task {
            // One session per conversation so the model keeps chat context.
            let session = chatSession ?? FinanceChatSession(modelContext: modelContext)
            chatSession = session
            do {
                let reply = try await session.send(text)
                messages.append(ChatMessage(role: .assistant, text: reply))
            } catch {
                messages.append(ChatMessage(role: .assistant, text: error.localizedDescription))
            }
            isThinking = false
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 48)
            }

            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    message.role == .user ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(message.role == .user ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))

            if message.role == .assistant {
                Spacer(minLength: 48)
            }
        }
        .id(message.id)
    }
}

#Preview {
    FinanceChatView()
        .modelContainer(
            for: [Account.self, Category.self, Transaction.self,
                  RecurringPayment.self, RecurringOccurrence.self,
                  Person.self, LendingEntry.self, Investment.self,
                  InvestmentOccurrence.self, CreditCardEMI.self,
                  EMIInstallment.self, CardPayment.self],
            inMemory: true
        )
}
