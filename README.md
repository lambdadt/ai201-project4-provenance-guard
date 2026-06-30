# Provenance Guard

A backend system for creative sharing platforms that classifies submitted text content as human-written or AI-generated, provides calibrated confidence scores, surfaces end-user transparency labels, and supports an appeals workflow for contested classifications.

## Features

- **Content Submission Endpoint** (`POST /submit`) — accepts text content and returns classification, confidence score, signal breakdown, and transparency label text.
- **Multi-Signal Detection Pipeline** — combines LLM-based semantic analysis (Groq) with structural stylometric heuristics for more reliable classification.
- **Confidence Scoring with Uncertainty** — returns a numeric score from 0.0 (definitely AI) to 1.0 (definitely human) with a meaningful middle band that honestly admits when the system is uncertain.
- **Transparency Labels** — three distinct, plain-language label variants displayed to readers alongside content.
- **Appeals Workflow** (`POST /appeal`) — creators can contest a classification; the submission status updates to "under review" and the appeal is logged.
- **Rate Limiting** — Flask-Limiter enforces per-endpoint, per-IP rate limits.
- **Audit Log** — SQLite-backed structured log of every classification decision and appeal.

## Setup

```bash
# Clone and enter the repo
cd ai201-project4-provenance-guard

# Create virtual environment and install dependencies
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Set your Groq API key
export GROQ_API_KEY="your-key-here"

# Run the server
python main.py
```

## API Reference

### `POST /submit`

Classify a piece of text content.

**Rate limit**: 10 requests per minute per IP.

**Request body:**
```json
{
  "content": "The text content to classify (minimum 50 characters)..."
}
```

**Success response (200):**
```json
{
  "submission_id": "a1b2c3d4-...",
  "attribution": "human",
  "confidence": 0.82,
  "label_variant": "human",
  "label_text": "Human-Written / Likely Human\n\nOur automated detection system found strong indicators...",
  "signals": {
    "llm": {
      "score": 0.85,
      "reason": "The text shows varied sentence structure and personal voice..."
    },
    "heuristics": {
      "score": 0.78,
      "detail": {
        "ttr": 0.72,
        "sentence_length_cv": 0.68,
        "punctuation_variety": 0.60,
        "hapax_ratio": 0.55
      }
    }
  }
}
```

**Error responses:** `400` (missing/invalid/short content), `429` (rate limit exceeded), `500` (server error).

### `POST /appeal`

Contest a classification decision.

**Rate limit**: 3 requests per minute per IP.

**Request body:**
```json
{
  "submission_id": "a1b2c3d4-...",
  "reason": "This is my original poetry. I use intentional repetition as a stylistic device."
}
```

**Success response (200):**
```json
{
  "submission_id": "a1b2c3d4-...",
  "status": "under_review",
  "message": "Appeal received. This submission is now under review."
}
```

**Error responses:** `400` (missing fields), `404` (submission not found), `409` (already appealed).

### `GET /log`

Retrieve recent audit log entries. Accepts optional query parameter `?limit=N` (default 20).

**Rate limit**: 30 requests per minute per IP.

### `GET /health`

Health check. Returns `{ "status": "ok" }`.

## Detection Signals

### Signal 1: LLM-Based Classification (Groq)

The text is sent to Groq's `llama-3.3-70b-versatile` model with a prompt that asks it to assess whether the writing reads as human or AI-generated. The model evaluates semantic coherence, authorial voice, emotional depth, and stylistic naturalness. It returns a score from 0.0 (definitely AI) to 1.0 (definitely human) along with a reasoning explanation.

This signal captures the **semantic and conceptual** qualities of the text that are difficult to measure statistically — tone, voice, narrative logic, emotional authenticity.

### Signal 2: Stylometric Heuristics

Pure-Python statistical analysis of the text's structural properties, producing four sub-metrics that are normalized to 0.0–1.0 and averaged:

| Sub-Metric                 | What It Measures                           | Human Tendency        | AI Tendency            |
|---------------------------|--------------------------------------------|-----------------------|------------------------|
| Type-Token Ratio (TTR)    | Vocabulary diversity (unique / total words)| Higher diversity      | More repetition        |
| Sentence Length CV         | Variation in sentence lengths              | High variation        | Uniform lengths        |
| Punctuation Variety Density| Distinct punctuation types per text length | More variety          | Mostly periods & commas|
| Hapax Legomena Ratio       | Words appearing exactly once / total words | Higher (creative)     | Lower (repetitive)     |

This signal captures the **structural and statistical** properties of the text — the "fingerprint" of how it's constructed, independent of meaning.

### Why Two Signals?

The two signals are genuinely independent: one reads the text for meaning (semantic), the other measures its shape (structural). Each has blind spots. The LLM can be fooled by formal writing that "sounds" AI-like. The heuristics can be fooled by poetry that uses intentional repetition. Together, they compensate for each other's weaknesses. When they agree, the system is confident. When they disagree, the system admits uncertainty.

### Scoring Combination

The combined confidence score is a weighted average:

```
combined_score = 0.6 × llm_score + 0.4 × heuristics_score
```

The LLM carries 60% weight because semantic analysis captures higher-level patterns. The heuristics carry 40% weight to provide a structural "check" that can pull borderline results toward uncertainty when the signals disagree.

## Confidence Scoring & Uncertainty

A confidence score is a number from 0.0 to 1.0:
- **0.0** = the system is fully confident this text is AI-generated.
- **1.0** = the system is fully confident this text is human-written.
- **0.5** = the system cannot tell — the signals are inconclusive or contradictory.

The score is **not** a binary classifier forced into two buckets. A 0.51 produces a meaningfully different label than a 0.95:

| Score | What It Means                                                                 |
|-------|-------------------------------------------------------------------------------|
| 0.15  | Both signals strongly indicate AI. The system is confident.                   |
| 0.51  | The signals produced a borderline result, barely above the midpoint. The system is uncertain and says so. |
| 0.82  | Both signals indicate human, with decent agreement. The system is fairly confident. |
| 0.95  | Both signals strongly agree on human authorship. The system is very confident. |

### Thresholds

| Range                  | Attribution    | Label Variant              |
|------------------------|----------------|----------------------------|
| combined_score < 0.4   | `ai`           | High-confidence AI         |
| 0.4–0.6                | `uncertain`    | Uncertain                  |
| combined_score > 0.6   | `human`        | High-confidence Human      |

The middle band (0.4–0.6) is deliberately wide — many real-world texts fall into a gray area, and Provenance Guard chooses to be honest about that rather than guessing.

### Validation Approach

To verify that scores are meaningful:
1. Run a set of known-human texts (Project Gutenberg, personal essays) through the pipeline — they should average above 0.6.
2. Run a set of known-AI texts (ChatGPT, Claude generations) — they should average below 0.4.
3. Flag cases where the two signals disagree by >0.3 — these should land in the uncertain band (0.4–0.6).
4. Spot-check individual results for reasonability — does a 0.15 score correspond to obviously AI-generated text? Does a 0.90 correspond to obviously human text?

## Transparency Labels

The three label variants designed to be shown to readers on a creative platform:

### Label Variants

| Variant                 | Threshold     | Label Text |
|-------------------------|---------------|------------|
| **High-Confidence AI**  | score < 0.4   | "**AI-Generated / Likely AI** Our automated detection system found strong indicators that this content may have been generated by AI rather than written by a human. Multiple analysis signals — including writing style patterns and text structure — suggest AI authorship. This label reflects our system's assessment, not a final determination. The creator may contest this classification." |
| **Uncertain**           | 0.4–0.6       | "**Uncertain Attribution** Our system couldn't determine with confidence whether this content was written by a human or generated by AI. The writing shows a mix of patterns — some characteristic of human authorship, some of AI generation. We display this label transparently rather than guessing. The creator may contest this classification." |
| **High-Confidence Human** | score > 0.6 | "**Human-Written / Likely Human** Our automated detection system found strong indicators that this content was written by a human. Multiple analysis signals — including vocabulary diversity, sentence rhythm, and stylistic patterns — suggest human authorship. This label reflects our system's assessment, not a guarantee. While we are confident in this result, no automated system is perfect." |

## Architecture

For the full architecture narrative, diagram, and design rationale, see [planning.md](planning.md).

**Submission flow summary**: `POST /submit` → Rate Limiter → Input Validation → Signal 1 (Groq LLM, semantic) + Signal 2 (Stylometrics, structural) → Confidence Scorer (weighted combination) → Transparency Label Generator → Audit Logger (SQLite) → JSON Response.

**Appeal flow summary**: `POST /appeal` → Validate submission ID → Update status to "under_review" → Log appeal reason → JSON Response.

## Rate Limiting

| Endpoint   | Limit          | Reasoning |
|------------|----------------|-----------|
| `POST /submit` | 10 / minute / IP | Protects the Groq API free-tier quota (capped at ~30 RPM). Allows 3 concurrent users at peak. Burst-friendly for a creative platform where individual users submit infrequently. |
| `POST /appeal` | 3 / minute / IP  | Appeals should be deliberate. Prevents spam while allowing legitimate use. |
| `GET /log`      | 30 / minute / IP | Read-only, low-cost. High enough for dashboard use, low enough to prevent scraping. |
| `GET /health`   | 60 / minute / IP | Lightweight, high-frequency OK. |

## Audit Log

Every classification decision and appeal is recorded in a SQLite database (`audit.db`). Each entry captures the full context of the decision: what was submitted, what both signals said, what the final score and label were, and whether an appeal was filed.

### Example Audit Log Entries

**Entry 1 — High-confidence Human (essay excerpt)**
```
submission_id:      f47ac10b-58cc-4372-a567-0e02b2c3d479
timestamp:          2026-06-30T14:22:10Z
content_hash:       a3f2b8c1...
content_length:     847
llm_score:          0.88
llm_reason:         "The text shows natural sentence rhythm variation, personal anecdotes, and occasional digressions characteristic of human writing."
heuristics_score:   0.74
heuristics_detail:  {"ttr": 0.68, "sentence_length_cv": 0.71, "punctuation_variety": 0.62, "hapax_ratio": 0.58}
combined_score:     0.82
attribution:        human
label_text:         "Human-Written / Likely Human... (full text)"
status:             classified
appeal_reason:      null
```

**Entry 2 — High-confidence AI (generated blog post)**
```
submission_id:      e3b0c442-98fc-4c3a-b9a4-1b0e8a3c2d1f
timestamp:          2026-06-30T14:25:33Z
content_hash:       d4e5f6a7...
content_length:     612
llm_score:          0.12
llm_reason:         "The text has an unnaturally consistent tone throughout, lacks any personal voice markers, and uses generic transition phrases typical of AI generation."
heuristics_score:   0.22
heuristics_detail:  {"ttr": 0.34, "sentence_length_cv": 0.28, "punctuation_variety": 0.18, "hapax_ratio": 0.25}
combined_score:     0.16
attribution:        ai
label_text:         "AI-Generated / Likely AI... (full text)"
status:             classified
appeal_reason:      null
```

**Entry 3 — Uncertain, then appealed (minimalist poem)**
```
submission_id:      c9d8e7f6-5a4b-3c2d-1e0f-a9b8c7d6e5f4
timestamp:          2026-06-30T14:30:01Z
content_hash:       b8a7c6d5...
content_length:     156
llm_score:          0.45
llm_reason:         "The text is abstract and sparse, making it difficult to distinguish between intentional human minimalism and AI generation attempting to appear poetic."
heuristics_score:   0.31
heuristics_detail:  {"ttr": 0.42, "sentence_length_cv": 0.22, "punctuation_variety": 0.10, "hapax_ratio": 0.38}
combined_score:     0.39
attribution:        ai
label_text:         "AI-Generated / Likely AI... (full text)"
status:             under_review
appeal_reason:      "This is my original haiku sequence. The repetition and simplicity are deliberate stylistic choices, not AI artifacts."
appeal_timestamp:   2026-06-30T14:35:42Z
```

Note: Entry 3 demonstrates a borderline case — the combined score is 0.39, just below the 0.4 threshold into "AI" territory. The heuristics flagged the simple structure as AI-like, while the LLM was uncertain. This is a realistic scenario for minimalist poetry, and the appeals process captures the creator's explanation for human review.

## Stack

| Component            | Technology                          | Notes |
|---------------------|-------------------------------------|-------|
| API framework       | Flask 3.x                           | Lightweight, minimal boilerplate |
| Detection signal 1  | Groq API (llama-3.3-70b-versatile)  | Semantic classification |
| Detection signal 2  | Pure Python (custom stylometrics)   | No external libraries needed |
| Rate limiting       | Flask-Limiter 3.x                   | Per-IP, per-endpoint limits |
| Audit log           | SQLite (built-in)                   | Single-file, zero-config database |
| Environment config  | python-dotenv                       | GROQ_API_KEY from .env |
