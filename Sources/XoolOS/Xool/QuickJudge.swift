import Foundation

/// The instant judgement for engines that don't bring their own (the Mac's speech recognition): the
/// same idea as the sidecar's `urteil.py`, in a few regular expressions. No model, a few microseconds.
/// "Does the model's own knowledge do, or are the web, the browser, the user's notes needed?"
enum QuickJudge {
    private static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "ß", with: "ss")
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    private static let brain = #"\b(meine[nrm]? (notiz|notizen|dateien|datei|dokumente?|unterlagen|lesezeichen|skills?)|(in|aus) (meinem|dem) (brain|second brain|archiv)|second brain|mein brain|was (habe|hab) ich (gespeichert|notiert|abgelegt)|my notes|my files)"#
    private static let browser = #"(\boeffne\b|\b(ruf|rufe|mach|mache|geh|gehe)\b.*\b(seite|website|webseite|tab|link|browser|mail|mails|posteingang|kalender)\b|\b\w+\.(com|de|org|net|io|ai|app)\b|\bneuen tab\b|\bopen (the )?(page|site|website)\b)"#
    private static let web = #"\b(aktuell\w*|neueste\w*|nachrichten|news|schlagzeilen|wetter|vorhersage|preis\w*|kurs|aktie\w*|bitcoin|ergebnis\w*|wer hat gewonnen|gewonnen|bundesliga|offnungszeiten|oeffnungszeiten|fahrplan|flug|fluege|such(e|st)?\b|recherchier\w*|google\w*|im internet|im netz|online|nachschlagen|latest|weather|search for|look up)\b"#
    private static let delegate = #"\b(delegier\w*|frag (mal )?(einen |den |die )?(assistent\w*|agent\w*)|lass (das )?(einen |den |die )?(assistent\w*|kollegen))\b"#

    static func judge(_ text: String, name: String) -> Heard {
        let f = fold(text)
        func has(_ pattern: String) -> Bool { f.range(of: pattern, options: .regularExpression) != nil }
        let named = f.range(of: "\\b\(fold(name))\\b", options: .regularExpression) != nil
        if has(brain) { return Heard(kind: "brain", route: "brain", tools: true, named: named) }
        if has(delegate) { return Heard(kind: "delegieren", route: "delegate", tools: true, named: named) }
        if has(browser) { return Heard(kind: "browser", route: "browser", tools: true, named: named) }
        if has(web) { return Heard(kind: "websuche", route: "web", tools: true, named: named) }
        let question = f.hasSuffix("?") ? "frage" : "erzaehlung"
        return Heard(kind: question, route: "wissen", tools: false, named: named)
    }
}
