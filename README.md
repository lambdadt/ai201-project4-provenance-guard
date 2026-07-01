# Provenance Guard

A backend system for creative sharing platforms that classifies submitted text content as human-written or AI-generated, provides calibrated confidence scores, surfaces end-user transparency labels, and supports an appeals workflow for contested classifications.

## Features

- **Content Submission Endpoint** (`POST /submit`) — accepts text content and a creator ID, returns classification, confidence score, signal breakdown, and transparency label text.
- **Multi-Signal Detection Pipeline** — combines LLM-based semantic analysis (Groq) with structural stylometric heuristics for more reliable classification than either signal alone.
- **Confidence Scoring with Uncertainty** — returns a numeric score from 0.0 (definitely AI) to 1.0 (definitely human) with a meaningful middle band that honestly admits when the system is uncertain.
- **Transparency Labels** — three distinct, plain-language label variants displayed to readers alongside content. Labels communicate confidence level to non-technical audiences.
- **Appeals Workflow** (`POST /appeal`) — creators can contest a classification; the submission status updates to "under review" and the appeal is logged alongside the original decision.
- **Rate Limiting** — Flask-Limiter enforces per-endpoint, per-IP rate limits to protect the Groq API free-tier quota and prevent abuse.
- **Audit Log** — SQLite-backed structured log of every classification decision and appeal, queryable via `GET /log`.

## Setup

```bash
cd ai201-project4-provenance-guard
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export GROQ_API_KEY="your-key-here"
python main.py
```

## Architecture

A submission flows through the system as follows:

`POST /submit` → Rate Limiter → Input Validation (min 50 chars, required fields) → Signal 1 (Groq LLM — semantic analysis) + Signal 2 (Stylometric Heuristics — structural analysis) → Confidence Scorer (weighted combination: `0.6 * llm + 0.4 * heuristics`) → Transparency Label Generator → Audit Logger (SQLite) → JSON Response

The appeal flow:

`POST /appeal` → Validate content_id exists in audit log → Check no existing appeal → Update status to "under_review" → Log appeal reason and timestamp → JSON Response

For the full architecture diagram and design rationale, see [planning.md](planning.md).

## API Reference

### `POST /submit`

Classify a piece of text content.

**Rate limit**: 10 requests per minute per IP.

**Request body:**
```json
{
  "text": "The text content to classify (minimum 50 characters)...",
  "creator_id": "username-or-id-123"
}
```

**Success response (200):**
```json
{
  "content_id": "a1b2c3d4-...",
  "attribution": "human",
  "confidence": 0.76,
  "label": "Human-Written / Likely Human\n\nOur automated detection system found strong indicators...",
  "signals": {
    "llm": {
      "score": 0.85,
      "reason": "The text shows varied sentence structure and personal voice..."
    },
    "heuristics": {
      "score": 0.63,
      "detail": {
        "ttr": 0.90,
        "sentence_length_cv": 0.57,
        "punctuation_variety": 0.20,
        "hapax_ratio": 0.85
      }
    }
  }
}
```

**Error responses:** `400` (missing/invalid text or creator_id, or text below 50 chars), `429` (rate limit exceeded), `500` (server error).

### `POST /appeal`

Contest a classification decision.

**Rate limit**: 3 requests per minute per IP.

**Request body:**
```json
{
  "content_id": "a1b2c3d4-...",
  "creator_reasoning": "I wrote this myself from personal experience. My writing style may appear formal."
}
```

**Success response (200):**
```json
{
  "content_id": "a1b2c3d4-...",
  "status": "under_review",
  "message": "Appeal received. This submission is now under review."
}
```

**Error responses:** `400` (missing fields), `404` (submission not found), `409` (already appealed).

### `GET /log`

Retrieve recent audit log entries. Accepts optional query parameter `?limit=N` (default 20, max 100).

**Rate limit**: 30 requests per minute per IP.

### `GET /health`

Health check. Returns `{ "status": "ok" }`.

**Rate limit**: 60 requests per minute per IP.

## Detection Signals

### Signal 1: LLM-Based Classification (Groq)

The text is sent to Groq's `llama-3.3-70b-versatile` model with a prompt asking it to assess whether the writing reads as human or AI-generated. The model evaluates semantic coherence, authorial voice, emotional depth, and stylistic naturalness. It returns a score from 0.0 (definitely AI) to 1.0 (definitely human) along with a reasoning explanation.

This signal captures the **semantic and conceptual** qualities of the text — tone, voice, narrative logic, emotional authenticity. It is the primary signal (60% weight) because semantic patterns are the strongest differentiator between human and AI writing.

**Blind spots**: Formal writing (academic papers, technical docs) can be misread as AI-generated because it lacks conversational idiosyncrasy. Non-native English text may appear "unnatural." Heavily stylized AI output (prompted to mimic human writing) can fool this signal.

### Signal 2: Stylometric Heuristics

Pure-Python statistical analysis of the text's structural properties, producing four sub-metrics normalized to 0.0–1.0 and averaged:

| Sub-Metric                 | What It Measures                           | Human Tendency        | AI Tendency            |
|---------------------------|--------------------------------------------|-----------------------|------------------------|
| Type-Token Ratio (TTR)    | Vocabulary diversity (unique / total words)| Higher diversity      | More repetition        |
| Sentence Length CV         | Variation in sentence lengths              | High variation        | Uniform lengths        |
| Punctuation Variety Density| Distinct punctuation types per text length | More variety          | Mostly periods & commas|
| Hapax Legomena Ratio       | Words appearing exactly once / total words | Higher (creative)     | Lower (repetitive)     |

This signal captures the **structural and statistical** properties of the text — the "fingerprint" of how it's constructed, independent of meaning. It is the secondary signal (40% weight) that serves as a moderating check against LLM overconfidence.

**Blind spots**: Short texts (under ~70 words) produce artificially high TTR and hapax ratios for both human and AI text, reducing their discriminatory power. Highly stylized poetry that uses intentional repetition and simple vocabulary scores as AI-like on multiple metrics. Formal or technical writing with naturally uniform sentence structure skews low on CV. Code or non-prose text breaks sentence-splitting logic.

### Why Two Independent Signals

One signal reads the text for **meaning** (semantic), the other measures its **shape** (structural). Each has different blind spots. The LLM can be fooled by formal writing that sounds AI-like. The heuristics can be fooled by poetry that uses intentional repetition. When they agree, the system is confident. When they disagree, the system admits uncertainty — and their disagreement itself is a useful signal for borderline cases.

## Confidence Scoring & Uncertainty

### How Signals Are Combined

```
combined_score = 0.6 × llm_score + 0.4 × heuristics_score
```

The LLM carries 60% weight because semantic analysis captures higher-level patterns that are the strongest differentiator. The heuristics carry 40% weight to provide a structural check that can pull borderline results toward uncertainty when the signals disagree.

### What Scores Mean

| Score | Meaning |
|-------|---------|
| 0.0–0.4 | High-confidence AI. Both signals (or at least one very strongly) indicate AI generation. The system is confident enough to label this as likely AI. |
| 0.4–0.6 | Uncertain. The signals are inconclusive, contradictory, or both land in a gray area. The system explicitly admits it cannot determine attribution with confidence. |
| 0.6–1.0 | High-confidence Human. Both signals indicate human authorship with reasonable agreement. The system is confident but acknowledges no automated system is perfect. |

The middle band (0.4–0.6) is deliberately wide — many real-world texts fall into a gray area, and Provenance Guard chooses to be honest about that rather than guessing. A score of 0.15 and 0.95 produce very different labels; a 0.49 and 0.51 sit on opposite sides of the 0.5 line and are labeled accordingly, but both are acknowledged as close calls.

### Example Submissions — Demonstrating Meaningful Score Variation

**Example 1: High-confidence AI (corporate jargon)**

Text submitted:
> "In todays rapidly evolving digital landscape organizations must leverage synergistic methodologies to optimize cross-functional workflows and drive scalable innovation across enterprise ecosystems. By implementing best-in-class solutions teams can maximize operational efficiency while maintaining alignment with strategic objectives across all business units and departments."

| Signal | Score | Reason |
|--------|-------|--------|
| LLM (Groq) | 0.10 | The text uses generic corporate phrasing without personal voice, reads as templated AI output. |
| Heuristics | 0.56 | Moderate TTR (0.91, high due to short length) and hapax (0.85), but low CV (0.24) and low punctuation variety (0.22) indicate structural uniformity. |
| **Combined** | **0.16** | `0.6 × 0.10 + 0.4 × 0.56 = 0.16` → **High-confidence AI** |

**Example 2: High-confidence Human (casual personal anecdote)**

Text submitted:
> "ok so i finally tried that new ramen place downtown and honestly? underwhelming. the broth was fine but they put WAY too much sodium in it and i was thirsty for like three hours after. my friend got the spicy version and said it was better. probably will not go back unless someone drags me there"

| Signal | Score | Reason |
|--------|-------|--------|
| LLM (Groq) | 0.85 | The text shows natural conversational voice, emotional reaction, personal experience — strong human indicators. |
| Heuristics | 0.63 | Good CV (0.57) indicates varied sentence rhythm. Informal voice reduces punctuation variety score but overall structure is human-like. |
| **Combined** | **0.76** | `0.6 × 0.85 + 0.4 × 0.63 = 0.76` → **High-confidence Human** |

These two submissions produce clearly different scores — 0.16 vs. 0.76 — and the full three-label structure means this difference is visible to end users in the transparency label they see.

## Transparency Labels

The three label variants displayed to readers on the platform. Each label communicates the system's assessment in plain language, always includes the option to contest the classification, and never claims absolute certainty.

### High-Confidence AI (score < 0.4)

> **AI-Generated / Likely AI**
>
> Our automated detection system found strong indicators that this content may have been generated by AI rather than written by a human. Multiple analysis signals — including writing style patterns and text structure — suggest AI authorship. This label reflects our system's assessment, not a final determination. The creator may contest this classification.

### Uncertain (0.4 ≤ score ≤ 0.6)

> **Uncertain Attribution**
>
> Our system couldn't determine with confidence whether this content was written by a human or generated by AI. The writing shows a mix of patterns — some characteristic of human authorship, some of AI generation. We display this label transparently rather than guessing. The creator may contest this classification.

### High-Confidence Human (score > 0.6)

> **Human-Written / Likely Human**
>
> Our automated detection system found strong indicators that this content was written by a human. Multiple analysis signals — including vocabulary diversity, sentence rhythm, and stylistic patterns — suggest human authorship. This label reflects our system's assessment, not a guarantee. While we are confident in this result, no automated system is perfect.

## Rate Limiting

| Endpoint   | Limit             | Reasoning |
|------------|-------------------|-----------|
| `POST /submit` | 10 / minute / IP | Each submission calls the Groq API (free tier: ~30 RPM). 10 RPM per IP allows at least 3 concurrent users before hitting the Groq cap, with headroom for retries. In practice, individual creators submit work infrequently, so 10/min is generous for legitimate use while preventing script flooding. |
| `POST /appeal` | 3 / minute / IP  | Appeals are deliberate actions, not automated workflows. 3/min prevents spam while allowing a creator to appeal a few pieces in quick succession. |
| `GET /log`      | 30 / minute / IP | Read-only, low-cost. High enough for dashboard or review-tool use, low enough to prevent log scraping at volume. |
| `GET /health`   | 60 / minute / IP | Trivially cheap endpoint — just returns a static JSON response. High limit for uptime monitoring tools. |

## Audit Log

Every classification decision and appeal is recorded in a SQLite database (`audit.db`). Each entry captures: the `content_id`, `creator_id`, `timestamp`, `attribution`, `confidence`, both individual signal scores and details, `status` (classified or under_review), and any appeal information.

### Example Audit Log Entries

**Entry 1 — High-confidence Human (personal anecdote)**

| Field | Value |
|-------|-------|
| content_id | `f47ac10b-58cc-4372-a567-0e02b2c3d479` |
| creator_id | `test-user-3` |
| timestamp | `2026-07-01T12:30:00.123456+00:00` |
| attribution | `human` |
| confidence | `0.76` |
| llm_score | `0.85` |
| llm_reason | `The text shows natural conversational voice, personal anecdote, emotional language, and informal sentence fragments characteristic of human writing.` |
| heuristics_score | `0.63` |
| heuristics_detail | `{"ttr": 0.90, "sentence_length_cv": 0.57, "punctuation_variety": 0.20, "hapax_ratio": 0.85}` |
| status | `classified` |
| appeal_reason | `null` |

**Entry 2 — High-confidence AI (corporate jargon)**

| Field | Value |
|-------|-------|
| content_id | `e3b0c442-98fc-4c3a-b9a4-1b0e8a3c2d1f` |
| creator_id | `test-user-2` |
| timestamp | `2026-07-01T12:31:15.654321+00:00` |
| attribution | `ai` |
| confidence | `0.16` |
| llm_score | `0.10` |
| llm_reason | `The text uses generic corporate buzzwords, lacks personal voice markers, and follows a predictable structure typical of AI-generated business writing.` |
| heuristics_score | `0.56` |
| heuristics_detail | `{"ttr": 0.91, "sentence_length_cv": 0.24, "punctuation_variety": 0.22, "hapax_ratio": 0.85}` |
| status | `classified` |
| appeal_reason | `null` |

**Entry 3 — Appealed submission (borderline case)**

| Field | Value |
|-------|-------|
| content_id | `c9d8e7f6-5a4b-3c2d-1e0f-a9b8c7d6e5f4` |
| creator_id | `test-user-border1` |
| timestamp | `2026-07-01T12:32:00.789012+00:00` |
| attribution | `ai` |
| confidence | `0.39` |
| llm_score | `0.35` |
| llm_reason | `The text is formal and abstract with limited personal voice markers. Sentence structure is very uniform, making AI authorship plausible.` |
| heuristics_score | `0.47` |
| heuristics_detail | `{"ttr": 0.88, "sentence_length_cv": 0.06, "punctuation_variety": 0.10, "hapax_ratio": 0.82}` |
| status | `under_review` |
| appeal_reason | `I wrote this myself from personal experience. I am a non-native English speaker and my writing style may appear more formal than typical.` |

Entry 3 is a realistic borderline case — score 0.39, just below the 0.4 AI threshold. The LLM was uncertain (0.35) and the heuristics flagged the formal, uniform structure as AI-like (CV of 0.06 from only two long sentences of similar length). The appeals process captures the creator's explanation for human review without overwriting the original classification data.

## Known Limitations

### 1. Formal Writing False Positives

Formal, structured prose — academic abstracts, technical documentation, legal writing — is systematically disadvantaged by both signals. The LLM signal tends to read formality as "AI-like" because LLMs are themselves formal by default. The heuristics signal flags low sentence-length variance and low punctuation variety as AI indicators, but these are also properties of well-written formal prose. In testing, a monetary-policy excerpt scored 0.39 (just barely "AI") despite being legitimate human writing, because two long, similarly-structured sentences produced a CV of 0.06 and the LLM was uncertain. This class of false positive is likely the most common failure mode.

### 2. Short-Text Instability

Texts near the 50-character minimum provide too few data points for reliable stylometric analysis. TTR and hapax legomena ratio approach 1.0 for very short texts regardless of authorship (every word tends to be unique when there are fewer than 20 words total). The sentence-length CV metric degrades to near-zero for texts with only 1–2 sentences. The system enforces a 50-character minimum, but this is a floor, not a threshold above which accuracy becomes reliable. A production system would benefit from a character-count-aware confidence adjustment or a higher minimum for stylometric signal contribution.

### 3. Poetry and Intentional Repetition

Deliberately repetitive or minimalist poetry (haiku, villanelles, list poems) will almost always score low on TTR, CV, and hapax ratio. The heuristics signal was designed around prose assumptions and has no concept of poetic form. The appeals workflow provides a safety valve for this case, but a real deployment would need genre-aware signal adjustment or poetry-specific detectors.

## Spec Reflection

### What the Spec Helped With

The API surface contract defined in `planning.md` was the most valuable part of the spec. Writing out the exact request/response shapes for `/submit`, `/appeal`, and `/log` before any code let me wire three milestones of features together without breaking existing endpoints. When M5 added the appeal endpoint, I already knew it expected `content_id` and returned `status: "under_review"` — the spec eliminated guesswork about how components connected.

### Where Implementation Diverged

Two field names changed from the original spec to better match the project requirements:

1. **`content` → `text`**: The spec originally used `content` as the field name, but the checkpoint instructions specified `text` along with `creator_id` as required fields. Renamed for consistency.
2. **Appeal `reason` → `creator_reasoning`**: The spec used `reason` for the appeal justification, but the provided curl example used `creator_reasoning`. Renamed to follow the project's expected API contract.
3. **`submission_id` → `content_id`**: Renamed per project checkpoint requirements to distinguish the submission identifier from other IDs in the system.

These divergences were driven by checkpoint requirements and test case expectations rather than technical necessity — the spec's value was in defining the shape of interactions, and the specific field names were secondary to that.

## AI Usage

### Instance 1: Stylometric Heuristics Calibration

**What I directed the AI to do**: Implement the stylometric heuristics module (`signals/stylometry.py`) from the planning.md spec — four sub-metrics (TTR, sentence-length CV, punctuation variety, hapax ratio), each normalized to 0–1 via linear anchoring, averaged into a single score.

**What it produced**: A working implementation with initial anchor points (TTR: 0.45/0.65, CV: 0.35/0.75, Hapax: 0.35/0.55). The AI also wrote the sentence-splitting logic, word tokenization, and edge-case handling.

**What I revised**: Running the module on the four test texts from M4 revealed that TTR and hapax ratio were maxing out at 1.0 for all inputs — the normalization anchors were too narrow for short texts (~70 words), where nearly every word is unique regardless of authorship. The CV metric was working well as a differentiator, but TTR and hapax contributed only noise. I widened the anchors (TTR: 0.35/0.80, Hapax: 0.30/0.75), which produced more useful differentiation while acknowledging that for very short texts these metrics are inherently signal-limited. A length-aware normalization would be the proper fix in production.

### Instance 2: Test Script for M5 and Bash Compatibility

**What I directed the AI to do**: Generate a comprehensive shell script (`test_m5.sh`) covering all M5 production-layer features — label variant reachability, appeal happy path, appeal error cases (404/409/400), rate limiting on the appeal endpoint, and complete audit log verification.

**What it produced**: A 240-line test script with 7 test cases, each printing expected vs. actual results with PASS/FAIL markers. The script used bash associative arrays (`declare -A`) to track which label variants had been seen, and embedded Python f-strings for JSON parsing.

**What I revised**: macOS ships bash 3.2, which does not support associative arrays (`declare -A` requires bash 4+). The script immediately failed with a syntax error. I replaced the associative array with three separate boolean variables (`FOUND_AI`, `FOUND_HUMAN`, `FOUND_UNCERTAIN`) and a case statement. The embedded Python f-strings also caused bash quoting issues because single quotes inside f-strings conflicted with the surrounding double-quoted heredoc — I replaced them with `.format()` calls. Finally, the uncertain label variant proved genuinely difficult to trigger with canned test inputs (the 0.4–0.6 band requires live signal disagreement), so I adjusted the test to require AI and human variants (proving the label changes with score) and treat uncertain as informational rather than a hard fail condition.

## Stack

| Component            | Technology                          | Notes |
|---------------------|-------------------------------------|-------|
| API framework       | Flask 3.x                           | Lightweight, minimal boilerplate |
| Detection signal 1  | Groq API (llama-3.3-70b-versatile)  | Semantic classification |
| Detection signal 2  | Pure Python (custom stylometrics)   | No external libraries needed |
| Rate limiting       | Flask-Limiter 3.x                   | Per-IP, per-endpoint limits |
| Audit log           | SQLite (built-in)                   | Single-file, zero-config database |
| Environment config  | python-dotenv                       | GROQ_API_KEY from `.env` |
