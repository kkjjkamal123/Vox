/// "Hey Vox" spotting on the recognizer's own output, so no separate wake-word model has to run.
///
/// The recognizer hears "Vox" many ways, especially in Indian English ("box", "works", "walks", "wax"),
/// so matching is loose. Strong forms ("hey" + something that sounds like vox) work anywhere; weak forms
/// that are also ordinary English ("he works", "hey folks") only count at the start of an utterance and
/// never hand leftovers to the language model, so conversation or a video playing nearby can't trigger actions.
enum Wake {
    /// Greetings that start "Hey Vox" anywhere in speech.
    static let lead: Set<String> = ["hey", "hi", "hay", "hei", "heh", "haye"]
    /// Words that start everyday phrases ("okay, works for me"): strong only before an unmistakable "vox".
    static let softLead: Set<String> = ["okay", "ok", "yo", "hello"]
    /// Clearly "vox": never a common word after a greeting.
    static let distinct: Set<String> = [
        "vox", "vocs", "vocks", "vax", "voxx", "vaux", "vox's", "wox", "vos", "voss", "vogs", "boks", "bocks", "vex", "vix",
        "box", "fox", "box's", "fox's", "fax",
    ]
    /// Misheard "vox" that is also a real word; fine after "hey", not after "okay".
    static let common: Set<String> = ["works", "walks", "woks", "wokes", "volks", "wax", "vodka", "vogue", "vauxhall"]
    /// Real phrases in their own right ("hey folks", "hi books"): only at the start of an utterance.
    static let weakOnly: Set<String> = ["folks", "books", "bucks"]
    static let weakLead: Set<String> = ["he", "a", "they", "the"]
    static let fused: Set<String> = ["heyvox", "hayvox", "heybox", "heyfox", "heyworks", "heywalks", "hivox"]

    /// Any word that can begin a wake phrase (the command stream waits to see what follows it).
    static let anyLead = lead.union(softLead)

    struct Match { let next: Int; let strong: Bool }

    static func find(_ norm: [String]) -> Match? {
        for i in norm.indices {
            if fused.contains(norm[i]) { return Match(next: i + 1, strong: true) }
            guard i + 1 < norm.count else { break }
            let w = norm[i + 1]
            if lead.contains(norm[i]), distinct.contains(w) || common.contains(w) || close(w) { return Match(next: i + 2, strong: true) }
            if softLead.contains(norm[i]), distinct.contains(w) && !["box", "fox", "fax", "box's", "fox's"].contains(w) || w == "vox" {
                return Match(next: i + 2, strong: true)
            }
        }
        return nil
    }

    /// Like `find`, but also accepts the weak forms ("He works") at the start of any sentence, using the raw
    /// words' punctuation to see where sentences begin.
    static func find(raw: [String]) -> Match? {
        let norm = raw.map(Parser.normalize)
        if let m = find(norm) { return m }
        // "the box", "a fox": ordinary English after an article, so only real misspellings of "vox" there.
        let afterGreeting = distinct.union(common).union(weakOnly)
        let afterPronoun = common.union(weakOnly).union(distinct.subtracting(["box", "fox", "fax", "box's", "fox's"]))
        for i in norm.indices.dropLast() where i == 0 || raw[i - 1].last.map({ ".?!".contains($0) }) == true {
            let w = norm[i + 1]
            if anyLead.contains(norm[i]) && afterGreeting.contains(w) || weakLead.contains(norm[i]) && afterPronoun.contains(w) {
                return Match(next: i + 2, strong: false)
            }
        }
        return nil
    }

    /// One edit away from "vox" ("vex", "wok", "vos"…).
    private static func close(_ w: String) -> Bool { w.count <= 4 && editDistance(w, "vox") <= 1 }
}
