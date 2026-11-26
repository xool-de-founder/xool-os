"""Bridge phrases ("Mhm.", "Gute Frage …") and a soft breath, ready to play instantly.

All phrases are turned into audio once at start, so playing one costs 0 ms.
A phrase is only played if the real answer is not ready yet – if the model is
fast, you hear the answer directly, like with a person who already knows.
"""

from __future__ import annotations

import hashlib
import random
import re
import threading
import time
from pathlib import Path

import numpy as np

from .phrasen import PHRASES, ROUTE_GROUP  # noqa: E402  (250+ phrases by situation)

# Old and short names for groups.
ALIAS = {"suche": "websuche", "web": "websuche"}

_W_WORDS = r"(wer|wie|was|wann|wo|warum|wieso|weshalb|welche[rsmn]?|wohin|woher|wofür|wieviel|kannst|könntest|weißt|hast|bist|ist|sind|gibt|gibts|kennst|meinst|denkst|findest)"
_COMMAND = r"(mach|stell|erinner|schreib|such|spiel|öffne|zeig|sag|nenn|erklär|erzähl|hilf|gib|lies|rechne|übersetz|setz|starte?|stopp|merk|notier|bitte)"
_FEELING_BAD = r"(traurig|müde|stress|gestresst|schlecht|krank|wütend|sauer|nervt|angst|sorge|einsam|kaputt|schlimm|blöd|mist)"
_FEELING_GOOD = r"(geschafft|super|toll|freu|glücklich|endlich|bestanden|gewonnen|geil|mega|yeah|juhu)"
_OPINION = r"(was (denkst|hältst|meinst) du|deine meinung|findest du|würdest du|was sagst du)"


def classify(text: str, name: str = "Jarvis") -> str:
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
    """Holds the bridge phrases as ready audio and picks one without repeating itself.

    The audio is made once and kept on disk (`cache_dir`), so the next start
    loads it in a moment instead of speaking 300 phrases again.
    """

    #: The same phrase is not offered again within this many seconds, nor within the last `memory` picks.
    min_gap = 240.0
    memory = 60

    def __init__(self, tts, phrases: dict[str, list[str]] | None = None, seed: int | None = None,
                 breath_chance: float = 0.3, cache_dir: Path | None = None):
        self.tts = tts
        self.phrases = phrases or PHRASES
        self.audio: dict[str, np.ndarray] = {}
        self.recent: list[str] = []
        self.said_at: dict[str, float] = {}
        self.rng = random.Random(seed)
        self.breath_chance = breath_chance
        self.breath = make_breath(tts.sample_rate) if breath_chance > 0 else None
        self.ready = threading.Event()
        self.cache_dir = cache_dir
        self.loaded_from_cache = 0

    def _key(self, phrase: str) -> Path | None:
        if self.cache_dir is None:
            return None
        tag = f"{getattr(self.tts, 'name', 'voice')}-{getattr(self.tts, 'speed', 1.0):.2f}-{self.tts.sample_rate}"
        h = hashlib.sha1(f"{tag}|{phrase}".encode()).hexdigest()[:20]
        return self.cache_dir / f"{h}.npy"

    def prepare(self, background: bool = True) -> None:
        def work():
            if self.cache_dir is not None:
                try:
                    self.cache_dir.mkdir(parents=True, exist_ok=True)
                except OSError:
                    self.cache_dir = None
            for group in self.phrases.values():
                for p in group:
                    if p in self.audio:
                        continue
                    f = self._key(p)
                    try:
                        if f is not None and f.is_file():
                            self.audio[p] = np.load(f)
                            self.loaded_from_cache += 1
                            continue
                        self.audio[p] = self.tts.synth(p)
                        if f is not None:
                            np.save(f, self.audio[p].astype(np.float32))
                    except Exception:
                        pass
            self.ready.set()

        if background:
            threading.Thread(target=work, daemon=True).start()
        else:
            work()

    def count(self) -> int:
        return len({p for g in self.phrases.values() for p in g})

    def pick(self, kind: str) -> tuple[str, np.ndarray] | None:
        kind = ALIAS.get(kind, kind)
        group = [p for p in self.phrases.get(kind) or self.phrases["erzaehlung"] if p in self.audio]
        if not group:
            return None
        now = time.monotonic()
        fresh = [p for p in group if p not in self.recent and now - self.said_at.get(p, -1e9) > self.min_gap]
        if not fresh:  # the group is small: the one said longest ago
            fresh = sorted(group, key=lambda p: self.said_at.get(p, -1e9))[:max(1, len(group) // 3)]
        phrase = self.rng.choice(fresh)
        self.recent = (self.recent + [phrase])[-self.memory:]
        self.said_at[phrase] = now
        return phrase, self.audio[phrase]

    def maybe_breath(self) -> np.ndarray | None:
        if self.breath is not None and self.rng.random() < self.breath_chance:
            return self.breath
        return None
