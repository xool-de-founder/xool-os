"""Bridge phrases ("Mhm.", "Gute Frage …") and a soft breath, ready to play instantly.

All phrases are turned into audio once at start, so playing one costs 0 ms.
A phrase is only played if the real answer is not ready yet – if the model is
fast, you hear the answer directly, like with a person who already knows.
"""

from __future__ import annotations

import random
import re
import threading

import numpy as np

# About 100 phrases, sorted by situation.
PHRASES: dict[str, list[str]] = {
    "frage": [
        "Hm, gute Frage.", "Moment, ich überlege kurz.", "Lass mich kurz nachdenken.",
        "Hmm.", "Gute Frage.", "Spannende Frage.", "Hm, warte mal.", "Oh, gute Frage.",
        "Moment.", "Hm, lass mich überlegen.", "Ah, okay.", "Na ja, mal sehen.",
        "Hm, ja.", "Ja, also.", "Okay, Moment.", "Hmm, interessant.", "Also, hm.",
        "Hm, da muss ich kurz überlegen.", "Ah, das ist eine gute Frage.", "Ähm, ja.",
    ],
    "befehl": [
        "Okay.", "Alles klar.", "Mach ich.", "Klar.", "Geht klar.", "Gerne.",
        "Okay, mach ich.", "Jawohl.", "Ja, klar.", "Sofort.", "Okay, gerne.",
        "Alles klar, Moment.", "Kein Problem.", "Klar, mach ich.", "In Ordnung.",
        "Okay, einen Moment.", "Gut, mach ich.", "Ja, gerne.", "Wird gemacht.", "Okidoki.",
    ],
    "erzaehlung": [
        "Mhm.", "Ah, verstehe.", "Ja, okay.", "Aha.", "Ich verstehe.", "Oh, interessant.",
        "Ah ja.", "Okay.", "Ja.", "Verstehe.", "Ah, okay.", "Hm, ja.", "Oh.",
        "Ach so.", "Ja, verstehe.", "Ah, spannend.", "Okay, verstehe.", "Mhm, ja.",
        "Ich verstehe, was du meinst.", "Ah, alles klar.",
    ],
    "gefuehl": [
        "Oh, das klingt nicht schön.", "Hm, verstehe ich gut.", "Oh je.", "Ach, Mensch.",
        "Das kann ich verstehen.", "Oh, das tut mir leid.", "Hm, das ist echt nicht leicht.",
        "Puh, verstehe.", "Oh, okay.", "Mhm, das verstehe ich.",
    ],
    "freude": [
        "Oh, wie schön!", "Ah, super!", "Wow!", "Oh, toll!", "Cool!", "Klasse!",
        "Oh, das freut mich!", "Nice!", "Ha, super.", "Oh, sehr gut!",
    ],
    "meinung": [
        "Hm, wenn du mich fragst …", "Hm, lass mich kurz überlegen, was ich davon halte.",
        "Gute Frage, ich sag mal so.", "Hm, ehrlich gesagt.", "Also, ich finde, hm.",
        "Da hab ich eine Meinung.", "Hm, schwierig.", "Na ja, also.", "Hm, ich glaube.",
        "Also, wenn ich ehrlich bin.",
    ],
    "suche": [
        "Moment, ich schau kurz nach.", "Ich schau mal nach.", "Sekunde, ich suche das raus.",
        "Okay, ich guck mal im Internet.", "Moment, ich check das kurz.", "Einen Augenblick, ich suche.",
        "Ich schau schnell nach.", "Warte, ich such das kurz.",
    ],
    "hallo": [
        "Ja?", "Ja, ich bin da.", "Hi!", "Hallo!", "Hey!", "Ja, was gibt's?",
        "Hier bin ich.", "Ja, ich höre.", "Hey, was kann ich tun?", "Hallo, ja?",
    ],
}

_W_WORDS = r"(wer|wie|was|wann|wo|warum|wieso|weshalb|welche[rsmn]?|wohin|woher|wofür|wieviel|kannst|könntest|weißt|hast|bist|ist|sind|gibt|gibts|kennst|meinst|denkst|findest)"
_COMMAND = r"(mach|stell|erinner|schreib|such|spiel|öffne|zeig|sag|nenn|erklär|erzähl|hilf|gib|lies|rechne|übersetz|setz|starte?|stopp|merk|notier|bitte)"
_FEELING_BAD = r"(traurig|müde|stress|gestresst|schlecht|krank|wütend|sauer|nervt|angst|sorge|einsam|kaputt|schlimm|blöd|mist)"
_FEELING_GOOD = r"(geschafft|super|toll|freu|glücklich|endlich|bestanden|gewonnen|geil|mega|yeah|juhu)"
_OPINION = r"(was (denkst|hältst|meinst) du|deine meinung|findest du|würdest du|was sagst du)"


def classify(text: str, name: str = "Xool") -> str:
    """Rough situation of what the user said, to pick a fitting bridge phrase."""
    t = text.lower().strip()
    t_wo_name = re.sub(rf"\b{re.escape(name.lower())}\b[,!.?]*", "", t).strip(" ,.!?")
    if not t_wo_name or re.fullmatch(r"(hey|hallo|hi|na|servus|moin|guten (morgen|tag|abend))\W*", t_wo_name):
        return "hallo"
    if re.search(_OPINION, t):
        return "meinung"
    if re.search(rf"\b{_FEELING_BAD}", t):
        return "gefuehl"
    if re.search(rf"\b{_FEELING_GOOD}", t):
        return "freude"
    if re.match(rf"{_COMMAND}\w*\b", t_wo_name) or re.match(r"(kannst|könntest) du (mal |bitte )?\w+", t_wo_name) and not t.endswith("?"):
        return "befehl"
    if t.endswith("?") or re.match(rf"{_W_WORDS}\b", t_wo_name):
        return "frage"
    return "erzaehlung"


# Words an answer often starts with. If we already said a bridge phrase,
# we cut these off the start of the real answer so it does not sound doubled.
_LEADING = re.compile(
    r"^\s*((ja|nein|okay|ok|klar|also|hm+|ähm|äh|gute frage|alles klar|gerne|natürlich|"
    r"na ja|oh|ah|aha|mhm|sicher|genau|super|interessant|verstehe|ich verstehe)[,.!…]*\s+)+",
    re.I,
)


def strip_leading_filler(text: str) -> str:
    out = _LEADING.sub("", text, count=1).lstrip()
    if not out:
        return text
    return out[0].upper() + out[1:]


def make_breath(sample_rate: int, seconds: float = 0.38, volume: float = 0.07, seed: int = 0) -> np.ndarray:
    """A soft, short in-breath: shaped noise that swells and fades (no extra files needed)."""
    rng = np.random.default_rng(seed)
    n = int(sample_rate * seconds)
    noise = rng.standard_normal(n).astype(np.float32)
    # Smooth the noise (simple low-pass) so it sounds airy, not hissy.
    k = max(3, sample_rate // 2500)
    noise = np.convolve(noise, np.ones(k, np.float32) / k, mode="same")
    noise -= np.convolve(noise, np.ones(k * 8, np.float32) / (k * 8), mode="same")  # take out rumble
    t = np.linspace(0, 1, n, dtype=np.float32)
    env = np.clip(np.sin(np.pi * t), 0.0, 1.0) ** 1.5 * (0.6 + 0.4 * t)
    out = noise * env
    peak = float(np.max(np.abs(out))) or 1.0
    pause = np.zeros(int(sample_rate * 0.08), np.float32)
    return np.concatenate([out / peak * volume, pause]).astype(np.float32)


class FillerBank:
    """Holds the bridge phrases as ready audio and picks one without repeating itself."""

    def __init__(self, tts, phrases: dict[str, list[str]] | None = None, seed: int | None = None,
                 breath_chance: float = 0.3):
        self.tts = tts
        self.phrases = phrases or PHRASES
        self.audio: dict[str, np.ndarray] = {}
        self.recent: list[str] = []
        self.rng = random.Random(seed)
        self.breath_chance = breath_chance
        self.breath = make_breath(tts.sample_rate) if breath_chance > 0 else None
        self.ready = threading.Event()

    def prepare(self, background: bool = True) -> None:
        def work():
            for group in self.phrases.values():
                for p in group:
                    if p not in self.audio:
                        try:
                            self.audio[p] = self.tts.synth(p)
                        except Exception:
                            pass
            self.ready.set()

        if background:
            threading.Thread(target=work, daemon=True).start()
        else:
            work()

    def count(self) -> int:
        return sum(len(g) for g in self.phrases.values())

    def pick(self, kind: str) -> tuple[str, np.ndarray] | None:
        group = [p for p in self.phrases.get(kind) or self.phrases["erzaehlung"] if p in self.audio]
        if not group:
            return None
        fresh = [p for p in group if p not in self.recent] or group
        phrase = self.rng.choice(fresh)
        self.recent = (self.recent + [phrase])[-12:]
        return phrase, self.audio[phrase]

    def maybe_breath(self) -> np.ndarray | None:
        if self.breath is not None and self.rng.random() < self.breath_chance:
            return self.breath
        return None
