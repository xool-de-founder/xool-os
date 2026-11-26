"""Text helpers: clean text for speech, spot Whisper's inventions on silence."""

from __future__ import annotations

import re

_EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF‍️]+"
)
_URL = re.compile(r"https?://\S+")
_MD_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_THINK_BLOCK = re.compile(r"<think>.*?</think>", re.S)


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
    text = text.replace("&", " und ").replace("%", " Prozent")
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
