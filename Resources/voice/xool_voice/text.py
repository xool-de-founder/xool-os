"""Text helpers: clean text for speech, spot Whisper's inventions on silence."""

from __future__ import annotations

import re

_EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF‍️]+"
)
_URL = re.compile(r"https?://\S+")
_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.S)


_UNITS = [
    (r"(\d)\s?°\s?C\b", r"\1 Grad Celsius"), (r"(\d)\s?°", r"\1 Grad"), (r"(\d)\s?km/h", r"\1 Kilometer pro Stunde"),
    (r"(\d)\s?€", r"\1 Euro"), (r"€\s?(\d)", r"\1 Euro"), (r"(\d)\s?\$", r"\1 Dollar"),
    (r"(\d)\s?km\b", r"\1 Kilometer"), (r"(\d)\s?kg\b", r"\1 Kilogramm"), (r"(\d)\s?GB\b", r"\1 Gigabyte"),
    (r"(\d)\s?MB\b", r"\1 Megabyte"), (r"\bz\. ?B\.", "zum Beispiel"), (r"\bd\. ?h\.", "das heißt"),
    (r"\bca\.", "circa"), (r"\bu\. ?a\.", "unter anderem"), (r"\bbzw\.", "beziehungsweise"),
    (r"(\d),(\d)", r"\1 Komma \2"), (r"(\d)\.(\d{3})\b", r"\1\2"), (r"(\d)\s?-\s?(\d)", r"\1 bis \2"),
    (r"(\d)\s?\+\s?(\d)", r"\1 plus \2"),
]


def _speakable(text: str) -> str:
    """Numbers, units and abbreviations the way a person says them."""
    text = text.replace("&", " und ").replace("%", " Prozent")
    for pattern, repl in _UNITS:
        text = re.sub(pattern, repl, text)
    return text


def clean_for_speech(text: str) -> str:
    """Remove things a voice should not read aloud (markdown, emoji, links)."""
    text = _THINK_BLOCK.sub(" ", text)
    text = _MD_LINK.sub(r"\1", text)
    text = _URL.sub(" Link ", text)
    text = _EMOJI.sub(" ", text)
    text = re.sub(r"`{1,3}", "", text)
    text = re.sub(r"(\*\*|__|\*|~~)", "", text)
    text = re.sub(r"^\s{0,3}#{1,6}\s*", "", text, flags=re.M)  # headings
    text = re.sub(r"^\s*[-•*+]\s+", "", text, flags=re.M)  # bullets
    text = re.sub(r"^\s*\d+[.)]\s+", "", text, flags=re.M)  # numbered lists
    text = _speakable(text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


# Phrases Whisper likes to invent on silence or noise (well known for German).
_HALLUCINATIONS = [
    "untertitel", "amara.org", "vielen dank fürs zuschauen", "vielen dank für's zuschauen",
    "danke fürs zuschauen", "bis zum nächsten mal", "swr", "zdf", "copyright",
    "abonniert", "tschüss und bis bald",
]


def looks_like_hallucination(text: str) -> bool:
    t = text.lower().strip()
    if not t or not re.search(r"\w", t):
        return True
    if len(t) < 2:
        return True
    return any(h in t for h in _HALLUCINATIONS) and len(t.split()) <= 8
