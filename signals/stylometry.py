import math
import re
from collections import Counter

PUNCTUATION_CHARS = set(".,;:!?—-()\"'…")


def _split_sentences(text: str) -> list[str]:
    collapsed = re.sub(r"\.{2,}", ".", text)
    sentences = re.split(r"[.!?]+", collapsed)
    return [s.strip() for s in sentences if s.strip()]


def _tokenize_words(text: str) -> list[str]:
    return re.findall(r"[a-zA-Z]+", text.lower())


def _compute_ttr(words: list[str]) -> float:
    if not words:
        return 0.5
    return len(set(words)) / len(words)


def _compute_sentence_cv(sentences: list[str]) -> float:
    if len(sentences) < 2:
        return 0.0
    lengths = [len(_tokenize_words(s)) for s in sentences]
    mean_len = sum(lengths) / len(lengths)
    if mean_len == 0:
        return 0.0
    variance = sum((l - mean_len) ** 2 for l in lengths) / len(lengths)
    return math.sqrt(variance) / mean_len


def _compute_punctuation_score(text: str) -> float:
    punct_chars = [c for c in text if c in PUNCTUATION_CHARS]
    if not punct_chars:
        return 0.5
    total_punct = len(punct_chars)
    distinct_types = len(set(punct_chars))
    max_types = len(PUNCTUATION_CHARS)

    variety = distinct_types / max_types
    density = min(total_punct / max(len(text), 1) * 20, 1.0)
    return variety * 0.6 + density * 0.4


def _compute_hapax_ratio(words: list[str]) -> float:
    if not words:
        return 0.5
    counts = Counter(words)
    hapax = sum(1 for c in counts.values() if c == 1)
    return hapax / len(words)


def _normalize(value: float, ai_anchor: float, human_anchor: float) -> float:
    if human_anchor <= ai_anchor:
        return 0.5
    slope = 0.6 / (human_anchor - ai_anchor)
    score = 0.2 + slope * (value - ai_anchor)
    return max(0.0, min(1.0, score))


def analyze_text(text: str) -> tuple[float, dict]:
    if not text or not text.strip():
        return (0.5, {
            "ttr": 0.5,
            "sentence_length_cv": 0.5,
            "punctuation_variety": 0.5,
            "hapax_ratio": 0.5,
        })

    sentences = _split_sentences(text)
    words = _tokenize_words(text)

    raw_ttr = _compute_ttr(words)
    raw_cv = _compute_sentence_cv(sentences)
    raw_punct = _compute_punctuation_score(text)
    raw_hapax = _compute_hapax_ratio(words)

    ttr_score = _normalize(raw_ttr, ai_anchor=0.35, human_anchor=0.80)
    cv_score = _normalize(raw_cv, ai_anchor=0.35, human_anchor=0.75)
    punct_score = raw_punct
    hapax_score = _normalize(raw_hapax, ai_anchor=0.30, human_anchor=0.75)

    combined = round((ttr_score + cv_score + punct_score + hapax_score) / 4, 2)

    detail = {
        "ttr": round(ttr_score, 2),
        "sentence_length_cv": round(cv_score, 2),
        "punctuation_variety": round(punct_score, 2),
        "hapax_ratio": round(hapax_score, 2),
    }

    return (combined, detail)
