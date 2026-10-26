import SwiftUI

/// Where the user is in a question card: which question, what they've picked, and anything they typed.
struct QuestionProgress: Equatable {
    var index = 0
    var picks: [Set<Int>]
    var other: [String]

    init(count: Int) {
        picks = Array(repeating: [], count: count)
        other = Array(repeating: "", count: count)
    }
}

struct QuestionActions {
    let toggle: @MainActor (Int) -> Void
    let setOther: @MainActor (String) -> Void
    let back: @MainActor () -> Void
    let next: @MainActor () -> Void
    let handBack: @MainActor () -> Void
    let goToSession: (@MainActor () -> Void)?
}

struct QuestionCard: View {
    let prompt: QuestionPrompt
    let sessionName: String
    let progress: QuestionProgress
    let accent: LinearGradient
    let actions: QuestionActions
    @State private var hovered: Int?

    private var question: Question { prompt.questions[progress.index] }
    private var isLast: Bool { progress.index == prompt.questions.count - 1 }
    private var typed: String { progress.other[progress.index].trimmingCharacters(in: .whitespaces) }
    private var hasAnswer: Bool { !progress.picks[progress.index].isEmpty || !typed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(question.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index, option)
                }
            }
            HStack(spacing: 8) {
                TextField("Other", text: Binding(get: { progress.other[progress.index] }, set: { actions.setOther($0) }),
                          prompt: Text("Other\u{2026}").foregroundStyle(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                    .onSubmit { if hasAnswer { actions.next() } }
                if progress.index > 0 {
                    Button("Back", action: actions.back).buttonStyle(NotchPillStyle(prominent: false, accent: accent))
                }
                // A single choice answers with one click; a button is only needed to finish anything else.
                if question.multiSelect || !typed.isEmpty || prompt.questions.count > 1 && hasAnswer {
                    Button(isLast ? "Send" : "Next", action: actions.next)
                        .buttonStyle(NotchPillStyle(prominent: true, accent: accent))
                        .disabled(!hasAnswer)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question from \(sessionName)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent))
            }
            Text("\(sessionName) asks")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            if prompt.questions.count > 1 {
                Text("\(progress.index + 1) of \(prompt.questions.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 6)
            if let goToSession = actions.goToSession {
                Button(action: goToSession) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Go to the session")
                .accessibilityLabel("Go to the session")
            }
            Button("Answer in Claude", action: actions.handBack)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .help("Show this question in Claude instead")
        }
    }

    private func optionRow(_ index: Int, _ option: QuestionOption) -> some View {
        let selected = progress.picks[progress.index].contains(index)
        return Button { actions.toggle(index) } label: {
            HStack(spacing: 9) {
                Group {
                    if question.multiSelect {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                    } else {
                        Text("\(index + 1)").font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                }
                .foregroundStyle(selected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.6)))
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if option.preview != nil {
                    Image(systemName: "eye").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.14 : hovered == index ? 0.09 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent, lineWidth: 1).opacity(selected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .popover(isPresented: Binding(get: { hovered == index && option.preview != nil }, set: { if !$0, hovered == index { hovered = nil } }),
                 arrowEdge: .trailing) {
            ScrollView {
                Text(option.preview ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(width: 360, height: 220)
        }
        .help(option.description)
    }
}

struct NotchPillStyle: ButtonStyle {
    let prominent: Bool
    let accent: LinearGradient
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.14))))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
