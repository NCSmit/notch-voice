import AppKit
import SwiftUI

/// Where the user is in a question card: which question, what they've picked, and any "Other" text.
struct QuestionProgress: Equatable {
    var index = 0
    var picks: [Set<Int>]
    var other: [String]

    init(count: Int) {
        picks = Array(repeating: [], count: count)
        other = Array(repeating: "", count: count)
    }
}

/// What a spoken answer to the question on screen means.
enum QuestionVoiceAction: Equatable {
    case pick([Int])
    case other(String)
    case next
    case handBack
}

enum QuestionVoice {
    private static let ordinals = ["one": 0, "first": 0, "two": 1, "second": 1, "three": 2, "third": 2, "four": 3, "fourth": 3]

    /// Reads a whole spoken phrase as an answer to `question`, or nil when it isn't one. Only whole phrases count,
    /// so talk that merely mentions an option doesn't pick it.
    static func parse(_ spoken: String, for question: Question) -> QuestionVoiceAction? {
        let digits = ["1": " one ", "2": " two ", "3": " three ", "4": " four "]
        var text = spoken
        for (digit, word) in digits { text = text.replacingOccurrences(of: digit, with: word) }
        let words = WakeWordListener.normalized(text)
        guard !words.isEmpty else { return nil }

        if words.range(of: "^(answer|reply|respond) (it )?in claude$", options: .regularExpression) != nil { return .handBack }
        if ["next", "done", "send", "send it", "that's it", "submit"].contains(words) { return .next }
        if words.hasPrefix("other ") {
            let rest = String(spoken.drop(while: { $0 != " " })).trimmingCharacters(in: CharacterSet(charactersIn: " ,:;.-"))
            return rest.isEmpty ? nil : .other(rest)
        }
        // "option two", "the first one", "two and four", "last one"
        let count = question.options.count
        let ordinal = "(one|two|three|four|first|second|third|fourth|last)"
        let item = "((the )?(option|number|choice) )?(the )?\(ordinal)( one| option)?"
        if words.range(of: "^\(item)((,| and| plus) \(item))*$", options: .regularExpression) != nil {
            var picks: [Int] = []
            for word in words.split(separator: " ").map(String.init) {
                if word == "last" { picks.append(count - 1) } else if let index = ordinals[word] { picks.append(index) }
            }
            let valid = picks.filter { $0 >= 0 && $0 < count }
            if !valid.isEmpty, valid.count == picks.count { return .pick(question.multiSelect ? valid : [valid[0]]) }
            return nil
        }
        // An option's own name, said on its own.
        if let index = question.options.firstIndex(where: { WakeWordListener.normalized($0.label) == words }) {
            return .pick([index])
        }
        return nil
    }
}

struct QuestionCard: View {
    let prompt: QuestionPrompt
    let progress: QuestionProgress
    let accent: LinearGradient
    let toggle: @MainActor (Int) -> Void
    let setOther: @MainActor (String) -> Void
    let back: @MainActor () -> Void
    let next: @MainActor () -> Void
    let handBack: @MainActor () -> Void
    let goToSession: @MainActor () -> Void
    @State private var hovered: Int?

    private var question: Question { prompt.questions[progress.index] }
    private var isLast: Bool { progress.index == prompt.questions.count - 1 }
    private var hasAnswer: Bool {
        !progress.picks[progress.index].isEmpty || !progress.other[progress.index].trimmingCharacters(in: .whitespaces).isEmpty
    }

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
                TextField("", text: Binding(get: { progress.other[progress.index] }, set: { setOther($0) }),
                          prompt: Text("Other\u{2026}").foregroundStyle(.white.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                    .onSubmit { if hasAnswer { next() } }
                if progress.index > 0 {
                    Button("Back", action: back).buttonStyle(NotchPillStyle(prominent: false, accent: accent))
                }
                if question.multiSelect || !progress.other[progress.index].isEmpty || prompt.questions.count > 1 && hasAnswer {
                    Button(isLast ? "Send" : "Next", action: next)
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
        .accessibilityLabel("Question from \(prompt.sessionName)")
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
            Text("\(prompt.sessionName) asks")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
            if prompt.questions.count > 1 {
                Text("\(progress.index + 1) of \(prompt.questions.count)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 6)
            Button(action: goToSession) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .help("Go to the session")
            Button("Answer in Claude", action: handBack)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .help("Show this question in Claude instead")
        }
    }

    private func optionRow(_ index: Int, _ option: QuestionOption) -> some View {
        let selected = progress.picks[progress.index].contains(index)
        return Button { toggle(index) } label: {
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

/// "Auto mode blocked …", shown for a few seconds.
struct NoticeCard: View {
    let notice: BlockedNotice
    let goToSession: @MainActor () -> Void
    let dismiss: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto mode blocked: \(notice.title)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text([notice.detail, notice.project].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .font(.system(size: 10.5, design: .default))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Go to session", action: goToSession).buttonStyle(NotchPillStyle(prominent: false, accent: LinearGradient(colors: [.orange], startPoint: .leading, endPoint: .trailing)))
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
