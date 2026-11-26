"""The instant judgement (a few milliseconds, no model): what was said, and what does it need?

`judge(text)` answers two things before the real model has read a word:

* `route` – "wissen" (the model's own knowledge is enough), "web" (needs a
  search), "browser" (open or operate a page), "brain" (the user's own notes
  and files), "delegate" (hand it to an assistant) or "calc".
* `kind` – the situation for a bridge phrase (see phrasen.py).

The app then plays a fitting bridge phrase at once ("Moment, ich schau kurz im
Netz nach.") and gives the run only the tools it needs. A wrong guess is
harmless: the real model still has every tool when the route says so, and a
"wissen" answer that turns out to be unsure can say so in words.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

from .bruecken import classify


def _fold(text: str) -> str:
    t = text.lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    t = unicodedata.normalize("NFKD", t)
    return "".join(c for c in t if not unicodedata.combining(c))


_BRAIN = re.compile(
    r"\b(meine[nrm]? (notiz|notizen|dateien|datei|dokumente?|unterlagen|lesezeichen|skills?|gespeicherte)|"
    r"(in|aus) (meinem|dem) (brain|second brain|archiv)|second brain|mein brain|"
    r"was (habe|hab) ich (gespeichert|notiert|abgelegt|aufgeschrieben)|schau (mal )?in (meine|mein)\b|"
    r"such(e)? (in )?(meinen|meinem|meine)\b)", re.I)
_BROWSER = re.compile(
    r"(\b(oeffne|offne|geh|gehe|ruf|rufe|mach|mache|navigier\w*|klick\w*|fuell\w*|full\w*)\b.*\b(seite|website|webseite|tab|link|adresse|url|browser|mail|mails|posteingang|kalender|youtube|github|amazon|linkedin|google|wikipedia)\b|"
    r"\boeffne\b|\bauf (die |der )?(seite|website)\b|\b\w+\.(com|de|org|net|io|ai|app)\b|"
    r"\b(im )?browser\b|\bneuen tab\b|\bschau (dir|mal) (die )?(seite|website)\b)", re.I)
_WEB = re.compile(
    r"\b(aktuell\w*|neueste\w*|neuesten|nachrichten|news|schlagzeilen|wetter|vorhersage|"
    r"temperatur|preis\w*|kosten|kurs|aktie\w*|bitcoin|boerse|gewonnen|verloren|bundesliga|champions league|"
    r"ergebnis\w*|tabelle|wer hat gewonnen|oeffnungszeiten|fahrplan|abfahrt|flug|fluege|verspaetung|"
    r"such(e|st)?\b|suche|recherchier\w*|google\w*|im internet|im netz|online|nachschlagen|nachsehen|"
    r"laut (dem )?(internet|web)|quelle\w*|wer ist (der|die) (aktuelle|neue)|wie viele einwohner|release|erscheint|"
    r"2025|2026|2027|dieses jahr|diese woche|diesen monat|gerade eben|letzte\w* (woche|monat|jahr))\b", re.I)
_DELEGATE = re.compile(r"\b(delegier\w*|gib das (an|dem)|lass (das )?(einen |den |die )?(assistent\w*|kollegen)|frag (mal )?(einen |den |die )?(assistent\w*|agent\w*))\b", re.I)
_CALC = re.compile(r"\b(rechne|berechne|wie viel ist|wieviel ist|was ist \d|prozent von)\b|\d\s*[+\-*/x×:]\s*\d", re.I)
_THANKS = re.compile(r"^\W*(danke|dankeschoen|vielen dank|super danke|okay danke|alles klar danke)\W*$", re.I)
_BYE = re.compile(r"^\W*(tschuess|tschau|ciao|bis spaeter|bis bald|ich bin weg|gute nacht|das wars|das war's|danke das wars)\W*$", re.I)
_EXPLAIN = re.compile(r"\b(erklaer\w*|wie funktioniert|wie geht|was bedeutet|was ist ein|was ist eine|fass .* zusammen)\b", re.I)
_PRAISE = re.compile(r"\b(ich (habe|hab) (eine|'ne) idee|wie waere es|was haeltst du von|ich dachte|wir koennten|vorschlag)\b", re.I)
_THANKS_FOLD = _THANKS
_NAMES = ("jarvis", "jarwis", "dscharvis", "charvis", "harvis", "jarvies", "jarviss", "jarwiss", "tscharvis", "travis", "garvis", "tarvis", "yarvis", "dscharwis")


@dataclass
class Judgement:
    route: str  # wissen | web | browser | brain | delegate | calc
    kind: str  # a group of phrasen.PHRASES
    tools: bool  # needs the agent's tools
    named: bool  # the assistant's name was said

    def as_dict(self) -> dict:
        return {"route": self.route, "kind": self.kind, "tools": self.tools, "named": self.named}


def name_said(text: str, name: str = "Jarvis") -> bool:
    """Whether the name is in the sentence – Whisper writes it a little differently each time."""
    words = re.findall(r"[a-zäöüß]+", text.lower())
    mine = {_fold(name), *_NAMES} if _fold(name) == "jarvis" else {_fold(name)}
    for w in words:
        f = _fold(w)
        if f in mine:
            return True
        if len(f) >= 5 and any(_close(f, m) for m in mine):
            return True
    return False


def _close(a: str, b: str) -> bool:
    """Edit distance <= 1 for names of 5+ letters."""
    if abs(len(a) - len(b)) > 1:
        return False
    if len(a) == len(b):
        return sum(x != y for x, y in zip(a, b)) <= 1
    short, long_ = (a, b) if len(a) < len(b) else (b, a)
    for i in range(len(long_)):
        if long_[:i] + long_[i + 1:] == short:
            return True
    return False


def judge(text: str, name: str = "Jarvis") -> Judgement:
    f = _fold(text)
    named = name_said(text, name)
    rest = re.sub(r"\b(" + "|".join(_NAMES) + r")\b[,!.?]*", " ", f).strip()
    if _BYE.match(rest):
        return Judgement("wissen", "abschied", False, named)
    if _THANKS.match(rest):
        return Judgement("wissen", "danke", False, named)
    if _BRAIN.search(f):
        return Judgement("brain", "brain", True, named)
    if _DELEGATE.search(f):
        return Judgement("delegate", "delegieren", True, named)
    if _BROWSER.search(f):
        return Judgement("browser", "browser", True, named)
    if _WEB.search(f):
        return Judgement("web", "websuche", True, named)
    if _CALC.search(f):
        return Judgement("calc", "rechnen", False, named)
    if _EXPLAIN.search(f):
        return Judgement("wissen", "erklaeren", False, named)
    if _PRAISE.search(f):
        return Judgement("wissen", "lob", False, named)
    return Judgement("wissen", classify(text, name), False, named)
