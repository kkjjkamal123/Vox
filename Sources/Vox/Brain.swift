import Foundation
import FoundationModels

@Generable
struct CommandPlan {
    @Guide(description: """
        The user's request rewritten as simple commands, in order. Each command uses exactly one of these forms: \
        'open <app, website, folder or "<name> settings">', 'search <query> on <google|youtube|amazon|wikipedia|github|reddit|maps|spotify>', \
        'play <song or artist>' (add ' on youtube' only for videos, or ' on spotify' / ' on apple music' only if the user named it), 'type <exact text>', 'press <keys, e.g. command shift t>', 'quit <app>', \
        'set volume to <0-100>', 'set brightness to <0-100>', 'set a timer for <n> minutes', 'set an alarm for <time>', \
        'remind me to <task> <when>', 'make a note <text>', 'add event <title> <when>', "what's on my calendar", \
        "what's on my calendar tomorrow", 'what is the weather in <place>', 'will it rain tomorrow', 'convert <n> <unit> to <unit>', \
        'directions to <place>', 'where is <place>', 'open file <name>', 'message <person> saying <text>', \
        'whatsapp <person> saying <text>', 'email <person> about <subject> saying <text>', 'summarize this', 'translate this to <language>', \
        'make this more <style>', 'fix grammar', 'run shortcut <name>', 'turn on wifi', 'turn off wifi', 'new tab', 'close tab', 'go back', \
        'scroll down', 'scroll up', 'maximize', 'tile left', 'tile right', 'pause', 'resume', 'next track', 'previous track', 'volume up', 'volume down', 'mute', \
        'take screenshot', 'lock screen', 'toggle dark mode', 'empty trash', 'quit all apps', 'restart', 'shut down', "what's playing", \
        'what time is it', 'battery', 'how much storage', 'ask <question>'. \
        Use 'ask' for questions that need an answer rather than an action. Empty if nothing fits.
        """)
    var commands: [String]
}

/// On-device language model (Apple Foundation Models), used sparingly:
///  - rewriting phrasing the rule parser doesn't understand into commands it does (so the model can never
///    do anything outside the fixed command set), and
///  - answering spoken questions in a sentence or two.
@MainActor
final class Brain {
    var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    private static let rewriteInstructions = """
        You convert a spoken request for controlling a Mac into short commands. The speaker uses Indian English; \
        words may be misheard, so infer the most likely intent. Never invent a song, person, place or text the user \
        didn't say; if the request is unclear or just noise, return an empty list. Examples:
        "I wanna watch some lofi music" -> ["play lofi music on youtube"]
        "make it louder, like 80" -> ["set volume to 80"]
        "shut down chrome" -> ["quit google chrome"]
        "jot down buy milk in notes" -> ["make a note buy milk"]
        "find me flights to tokyo" -> ["search flights to tokyo on google"]
        "put on some arijit" -> ["play arijit singh"]
        "I want to hear tum hi ho" -> ["play tum hi ho"]
        "hold the music" -> ["pause"]
        "this song is boring" -> ["next track"]
        "wake me in 10 minutes" -> ["set a timer for 10 minutes"]
        "show me my downloads" -> ["open downloads"]
        "how tall is mount everest" -> ["ask how tall is mount everest"]
        "show me a random linus tech tips video" -> ["play random linus tech tips video on youtube"]
        "ping rahul that I'm running late" -> ["message rahul saying I'm running late"]
        "do I need a jacket today" -> ["what is the weather"]
        "how do I reach the airport" -> ["directions to the airport"]
        """

    func rewrite(_ utterance: String) async -> [String] {
        // A lone unknown word ("song", "the") is a misheard fragment; the model would invent a command for it.
        guard isAvailable, utterance.split(separator: " ").count >= 2 else { return [] }
        let session = LanguageModelSession(instructions: Self.rewriteInstructions)
        do {
            let r = try await session.respond(to: utterance, generating: CommandPlan.self,
                                              options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 96))
            return r.content.commands.map { Self.finishIntent(Self.keepService($0, said: utterance), said: utterance) }
        } catch {
            NSLog("Vox model error: \(error)")
            return []
        }
    }

    /// The model sometimes adds "on youtube" to a plain "play arijit": drop a service the user didn't ask
    /// for, so their default music app decides.
    static func keepService(_ command: String, said: String) -> String {
        let heard = said.lowercased()
        let mentions: [(String, [String])] = [(" on youtube", ["youtube", "video", "watch", "clip", "trailer", "vlog"]),
                                              (" on spotify", ["spotify"]), (" on apple music", ["apple music", "itunes"])]
        var c = command
        for (suffix, words) in mentions where c.lowercased().hasSuffix(suffix) && !words.contains(where: heard.contains) {
            c = String(c.dropLast(suffix.count))
        }
        return c
    }

    /// "show me a random LTT video" must play one, not stop at search results: the model often answers
    /// "search … on youtube" and drops "random". Only an explicit "search", "look up" or "find" stays a search.
    static func finishIntent(_ command: String, said: String) -> String {
        let heard = said.lowercased()
        let c = command.lowercased()
        guard c.hasPrefix("search "), c.hasSuffix(" on youtube"),
              !["search", "look up", "find", "results"].contains(where: heard.contains) else { return command }
        var what = String(command.dropFirst("search ".count).dropLast(" on youtube".count))
        for word in ["random", "latest", "newest"] where heard.contains(word) && !what.lowercased().contains(word) {
            what = word + " " + what
        }
        return "play \(what) on youtube"
    }

    /// Speech recognition mangles song titles, especially Hindi and other Indian-language ones
    /// ("Channa Mereya" -> "chan marrier"). Ask the model for the real title it most likely was.
    func correctSong(_ heard: String) async -> String {
        guard isAvailable else { return heard }
        // "kesariya by arijit": correct the title, keep the artist as said.
        if let r = heard.range(of: " by ", options: .caseInsensitive) {
            return await correctSong(String(heard[..<r.lowerBound])) + heard[r.lowerBound...]
        }
        let session = LanguageModelSession(instructions: """
            A speech recognizer transcribed the name of a song someone asked to play. The listener speaks Indian English \
            and often asks for Bollywood, Punjabi, Tamil, Telugu or English songs, and Hindi titles get transcribed as \
            English-sounding words. Reply with only the most likely real song title, nothing else, never an artist you weren't given. \
            If it already looks like a real title, or contains an artist name, repeat it unchanged.
            Examples: "chan marrier" -> Channa Mereya; "tum he ho" -> Tum Hi Ho; "blinding lights" -> blinding lights; \
            "arijit singh" -> arijit singh; "kesariya by arijit" -> kesariya by arijit
            """)
        do {
            let r = try await session.respond(to: heard, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24))
            let fixed = r.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'.")))
            // The model sometimes swaps in a different song from its examples ("arijit singh" -> "kesariya").
            // A real correction still sounds like what was heard.
            return fixed.isEmpty || fixed.count > 80 || Self.similarity(heard, fixed) < 0.5 ? heard : fixed
        } catch { return heard }
    }

    /// 0…1 closeness of two phrases by edit distance over letters only ("chan marrier" vs "Channa Mereya" ≈ 0.6).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter(\.isLetter)), y = Array(b.lowercased().filter(\.isLetter))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]; row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// Summarize, translate, rewrite… a piece of text.
    func transform(_ text: String, instruction: String) async -> String {
        guard isAvailable else { return "" }
        let session = LanguageModelSession(instructions: instruction + " No preamble, no markdown.")
        do {
            return try await session.respond(to: text).content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            NSLog("Vox model error: \(error)")
            return ""
        }
    }

    func answer(_ question: String) async -> String {
        guard isAvailable else { return "Apple Intelligence is turned off, so I can't answer questions." }
        // Ground factual answers in a few web results; the on-device model alone often gets facts wrong.
        let facts = await WebSearch.snippets(question)
        let session = LanguageModelSession(instructions: """
            You are Vox, a friendly voice assistant on a Mac. Answer in one or two short spoken sentences, no lists or markdown. \
            The user is in India unless they say otherwise. \
            If search results are given, base the answer on them and prefer them over your own memory. \
            If you don't know, say so briefly.
            """)
        let prompt = facts.isEmpty ? question
            : "Question: \(question)\n\nSearch results:\n" + facts.map { "- " + $0 }.joined(separator: "\n")
        do {
            return try await session.respond(to: prompt, options: GenerationOptions(maximumResponseTokens: 80)).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Sorry, I couldn't answer that."
        }
    }

}
