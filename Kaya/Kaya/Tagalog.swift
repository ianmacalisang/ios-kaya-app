//
//  Tagalog.swift
//  Kaya
//
//  Tagalog/Taglish understanding. Verified on iOS 26: there is no Filipino
//  speech recognizer in the SDK (SFSpeechRecognizer supports en-PH but no
//  fil/tl locale) and NLLanguageRecognizer can't detect Tagalog either —
//  it misclassifies Tagalog as Croatian/Indonesian. So detection scores the
//  transcript against a marker-word lexicon, and understanding is a
//  bilingual phrase table layered over the en-PH recognizer, which
//  transcribes Taglish far better than en-US.
//

import Foundation

enum Tagalog {

    /// High-signal Tagalog words, matched as whole tokens. Words that are
    /// also valid English ("at", "may", "pa") are deliberately excluded.
    static let markers: Set<String> = [
        // Pronouns & function words
        "ako", "ikaw", "ka", "mo", "ko", "siya", "kami", "tayo", "sila", "kayo",
        "niya", "namin", "natin", "nila", "ninyo", "kita",
        "ang", "ng", "mga", "sa", "na", "po", "opo", "oo", "hindi", "wala",
        "walang", "meron", "mayroon", "yung", "iyan", "yan", "ito", "eto",
        "diyan", "doon", "dito", "rin", "din", "ba", "nga", "muna", "lang",
        "lamang", "daw", "raw", "naman", "talaga", "kasi", "pero", "para",
        "dahil", "kung", "kapag", "habang", "kahit", "basta", "baka",
        "siguro", "dapat", "kailangan", "pwede", "puwede", "gusto", "ayaw",
        "masyado", "sobra", "konti", "kaunti", "marami", "madami", "lahat",
        "bago", "muli", "lagi", "minsan",
        // Time & days
        "ngayon", "bukas", "kahapon", "mamaya", "umaga", "tanghali", "hapon",
        "gabi", "araw", "linggo", "bawat", "tuwing", "alas",
        "lunes", "martes", "miyerkules", "myerkules", "huwebes", "webes",
        "biyernes", "byernes", "sabado",
        // Common verbs & commands
        "tapos", "natapos", "tulungan", "tulong", "ulitin", "ulit", "balik",
        "babalik", "bumalik", "simulan", "umpisahan", "ituloy", "tuloy",
        "sandali", "teka", "hintay", "hintayin", "laktawan", "sige", "huwag",
        "wag", "itigil", "tigil", "tama", "magluto", "maghugas", "maligo",
        "kumain", "kainin", "inumin", "uminom", "dalhin", "kunin", "isara",
        "buksan", "linisin", "ayusin", "gawin", "ipakita", "pakita", "basahin",
        "baguhin", "palitan", "tanggalin", "dagdagan", "bawasan", "madali",
        "mahirap", "hirap", "salamat", "paki", "susunod", "nakaraan",
        // Numbers
        "isa", "dalawa", "tatlo", "apat", "lima", "anim", "pito", "walo",
        "siyam", "sampu", "onse", "dose", "kalahati",
        // Question words
        "ano", "anong", "saan", "sino", "kailan", "bakit", "paano", "ilan",
        "magkano",
    ]

    /// Single words strong enough to mark the text as Tagalog on their own.
    static let strongMarkers: Set<String> = [
        "tapos", "natapos", "huwag", "ulitin", "laktawan", "magluto",
        "maghugas", "maligo", "kumain", "tulungan", "ituloy", "simulan",
        "umpisahan", "ngayon", "bukas", "mamaya", "tanghali", "hapon",
        "gabi", "lunes", "martes", "miyerkules", "myerkules", "huwebes",
        "biyernes", "byernes", "sabado", "linggo", "gusto", "ayaw",
        "hindi", "walang", "mayroon", "kailangan",
    ]

    /// Number words → value, for "alas otso" style times. Tagalog time uses
    /// Spanish-derived numbers, so both sets are here.
    static let numbers: [String: Int] = [
        "isa": 1, "una": 1, "dalawa": 2, "dos": 2, "tatlo": 3, "tres": 3,
        "apat": 4, "kwatro": 4, "kuwatro": 4, "lima": 5, "singko": 5,
        "anim": 6, "sais": 6, "pito": 7, "siyete": 7, "siete": 7,
        "walo": 8, "otso": 8, "siyam": 9, "nuwebe": 9, "nuebe": 9,
        "sampu": 10, "diyes": 10, "onse": 11, "dose": 12,
    ]

    /// Tagalog weekday names → Calendar weekday (1 = Sunday … 7 = Saturday).
    static let weekdays: [(name: String, weekday: Int)] = [
        ("linggo", 1), ("lunes", 2), ("martes", 3),
        ("miyerkules", 4), ("myerkules", 4), ("huwebes", 5), ("webes", 5),
        ("biyernes", 6), ("byernes", 6), ("sabado", 7),
    ]

    /// Split a transcript into lowercase word tokens for exact matching.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Count of distinct marker words found — the detection signal.
    static func score(_ text: String) -> Int {
        Set(tokens(text)).intersection(markers).count
    }

    /// True when the transcript is probably Tagalog/Taglish: one strong
    /// marker, or at least two markers anywhere in the text.
    static func isTagalog(_ text: String) -> Bool {
        let words = Set(tokens(text))
        if !words.isDisjoint(with: strongMarkers) { return true }
        return words.intersection(markers).count >= 2
    }

    /// Tagalog weekday lookup inside a spoken reply ("tuwing lunes", "sa
    /// biyernes"). Returns Calendar weekday 1–7, mirroring weekdayNamed.
    static func weekdayNamed(in t: String) -> Int? {
        for entry in weekdays where t.contains(entry.name) {
            return entry.weekday
        }
        return nil
    }

    /// Time from a Tagalog phrase: "alas 8", "alas otso", "alas 5:30",
    /// "ng umaga" (morning), "ng hapon" (afternoon), "ng gabi" (evening).
    /// Returns minutes since midnight, or nil.
    static func minutesNamed(in t: String) -> Int? {
        // "alas N[:MM]" first — N may be digits or a Tagalog number word,
        // and it beats bare part-of-day words ("alas 8 ng umaga" = 8:00,
        // not just "morning").
        let words = tokens(t)
        if let alasIndex = words.firstIndex(of: "alas"), alasIndex + 1 < words.count {
            var hour: Int?
            var minute = 0
            let hourToken = words[alasIndex + 1]
            if let digits = Int(hourToken) {
                hour = digits
                // "5:30" tokenizes as "5","30" — only pair them when the raw
                // text actually had a colon, otherwise "alas 5 30" stays 5:00.
                if t.contains(":"), alasIndex + 2 < words.count,
                   let mm = Int(words[alasIndex + 2]), (0..<60).contains(mm) {
                    minute = mm
                }
            } else if let word = numbers[hourToken] {
                hour = word
                // "y medya" / "y media" = half past.
                if t.contains("y medya") || t.contains("y media") {
                    minute = 30
                }
            }
            if var h = hour {
                // Part-of-day qualifier shifts the hour to PM.
                if t.contains("ng hapon") || t.contains("ng gabi") || t.contains("ng tanghali") {
                    if h < 12 { h += 12 }
                    // "Alas dose ng gabi" is midnight, not noon.
                    if h == 12, t.contains("ng gabi") { h = 0 }
                }
                guard (0..<24).contains(h), (0..<60).contains(minute) else { return nil }
                return h * 60 + minute
            }
        }

        // Bare part-of-day words.
        if t.contains("madaling araw") { return 5 * 60 }
        if t.contains("tanghali") { return 12 * 60 }
        if t.contains("umaga") { return 8 * 60 }
        if t.contains("hapon") { return 15 * 60 }
        if t.contains("gabi") { return 19 * 60 }
        return nil
    }
}
