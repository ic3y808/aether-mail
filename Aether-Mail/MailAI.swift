import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI for Aether Mail, running on Apple's Foundation Models (the
/// Neural Engine) — private, offline, no server. This is tier 1 of the planned
/// on-device → Mac → cloud routing; the Mac/cloud tiers layer in later.
enum MailAI {

    /// Whether on-device generation is usable right now (capable device with
    /// Apple Intelligence enabled and the model downloaded).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// A short, plain one-line summary of an email. Nil if AI is unavailable.
    static func summarize(subject: String, from: String, body: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            let session = LanguageModelSession(instructions: """
            You summarize an email in ONE short, plain sentence (about 20 words). Say what it's \
            about and any action the reader needs to take. No preamble, no quotes, no markdown.
            """)
            let prompt = "From: \(from)\nSubject: \(subject)\n\nBody:\n\(String(body.prefix(3000)))"
            do {
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// Free-form question about an open email (the Copilot ask box).
    static func ask(_ question: String, subject: String, from: String, body: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            let session = LanguageModelSession(instructions: """
            You are a helpful email assistant. Answer the user's question about the email below \
            concisely and plainly. If it asks you to draft a reply, write just the reply text.
            """)
            let prompt = """
            EMAIL —
            From: \(from)
            Subject: \(subject)

            \(String(body.prefix(3500)))

            QUESTION: \(question)
            """
            do {
                return try await session.respond(to: prompt).content
            } catch {
                return "Sorry — I couldn't answer that just now."
            }
        }
        #endif
        return nil
    }
}
