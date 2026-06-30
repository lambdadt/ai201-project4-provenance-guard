# Provenance Guard — Planning & Architecture

## Architecture Narrative

A piece of text takes the following path from submission to the label a user sees:

1. **POST /submit** — The client sends a JSON payload containing the text content (a poem, story excerpt, blog post, etc.).
2. **Rate Limiter** — Flask-Limiter intercepts the request and checks whether the client's IP address has exceeded the rate limit. If yes, the request is rejected with HTTP 429. This protects the Groq API free-tier quota and prevents abuse.
3. **Input Validation** — The endpoint validates that the content field is present, non-empty, and a string. Texts shorter than 50 characters are rejected with a 400 — they don't contain enough signal for either detector to make a meaningful assessment.
4. **Signal 1 — LLM-based Classification (Groq)** — The text is sent to Groq's `llama-3.3-70b-versatile` model with a structured prompt asking it to classify the text as human-written or AI-generated, on a scale from 0 (definitely AI) to 1 (definitely human), along with a brief reasoning explanation. The model returns a float score and a string reason.
5. **Signal 2 — Stylometric Heuristics** — A pure-Python module computes four statistical properties of the text:
   - **Type-Token Ratio (TTR)** — unique words divided by total words. Higher TTR indicates richer vocabulary diversity, characteristic of human writing.
   - **Sentence Length Coefficient of Variation (CV)** — standard deviation of sentence lengths divided by the mean. Human writing shows more variation; AI text is more uniform.
   - **Punctuation Variety Density** — a measure of how many distinct punctuation character types appear relative to text length, normalized. Human text uses more varied punctuation.
   - **Hapax Legomena Ratio** — the proportion of words that appear exactly once in the text. A high ratio suggests creative, varied word choice (human); a low ratio suggests repetition (AI).
   Each sub-metric is normalized to a 0–1 scale (0 = AI-like pattern, 1 = human-like pattern) and averaged into a single heuristics score.
6. **Confidence Scorer** — The two signal scores are combined via a weighted average: `combined_score = 0.6 * llm_score + 0.4 * heuristics_score`. The LLM signal carries more weight because semantic analysis captures higher-level patterns that stylometrics can't, but the heuristics score provides a structural check that can pull the result toward uncertainty if the LLM is overconfident.
7. **Transparency Label Generator** — The combined score is mapped to one of three label variants:
   - `combined_score < 0.4` → **High-confidence AI**
   - `0.4 <= combined_score <= 0.6` → **Uncertain**
   - `combined_score > 0.6` → **High-confidence Human**
   Each variant has a pre-written label text string that is included in the API response.
8. **Audit Logger** — A complete record is written to a SQLite database, capturing the submission ID, timestamp, content hash, both signal scores and reasoning, the combined score, the label variant, and the full label text. This log is the system's source of truth for every classification decision.
9. **Response** — The client receives a JSON response containing the attribution result (`ai`, `human`, or `uncertain`), the numeric combined confidence score, both individual signal scores, the transparency label text, and a unique submission ID for future reference or appeal.

### Appeal Flow

1. **POST /appeal** — A creator submits an appeal referencing a `submission_id` and providing their reasoning in the `reason` field.
2. **Validation** — The system looks up the submission ID in the audit log. If not found, returns 404. If an appeal already exists, returns 409.
3. **Status Update** — The submission's status changes from `classified` to `under_review`.
4. **Logging** — The appeal reason and timestamp are appended to the existing audit log entry.
5. **Response** — The client receives a confirmation with the submission ID and current status.

## Architecture Diagram

```
================================================================================
                           SUBMISSION FLOW
================================================================================

  Client
    │
    │  POST /submit  { "content": "..." }
    ▼
┌──────────────┐
│ Rate Limiter │ ──429──►  (if exceeded: reject)
│ (flask-lim)  │
└──────┬───────┘
       │ (allowed)
       ▼
┌──────────────────┐
│ Input Validation │ ──400──►  (if invalid: reject)
│ (min 50 chars)   │
└──────┬───────────┘
       │
       │ raw_text
       ├──────────────────────┐
       ▼                      ▼
┌─────────────┐    ┌─────────────────────┐
│  Signal 1   │    │     Signal 2         │
│  Groq LLM   │    │  Stylometric         │
│  (semantic) │    │  Heuristics (struct) │
└──────┬──────┘    └──────────┬──────────┘
       │                      │
       │ llm_score (0-1)     │ heuristics_score (0-1)
       │ llm_reason (str)    │ heuristics_detail (dict)
       │                      │
       └──────────┬───────────┘
                  │
                  ▼
    ┌──────────────────────────┐
    │   Confidence Scorer      │
    │   combined =              │
    │   0.6*llm + 0.4*heuristic │
    └────────────┬─────────────┘
                 │
                 │ combined_score (0-1)
                 ▼
    ┌──────────────────────────┐
    │ Transparency Label Gen   │
    │ <0.4 → AI                 │
    │ 0.4-0.6 → Uncertain       │
    │ >0.6 → Human              │
    └────────────┬─────────────┘
                 │
                 │ label_text, label_variant
                 ▼
    ┌──────────────────────────┐
    │      Audit Logger         │
    │    (SQLite database)      │
    └────────────┬─────────────┘
                 │
                 │ full audit record
                 ▼
    ┌──────────────────────────┐
    │    JSON Response          │
    │  { submission_id,         │
    │    attribution,           │
    │    confidence,            │
    │    signals,               │
    │    label_text }           │
    └──────────────────────────┘


================================================================================
                            APPEAL FLOW
================================================================================

  Client
    │
    │  POST /appeal  { "submission_id": "...", "reason": "..." }
    ▼
┌──────────────────┐
│ Validate          │ ──404──►  (submission not found)
│ submission_id    │ ──409──►  (appeal already exists)
│ exists in log    │
└──────┬───────────┘
       │ (valid)
       ▼
┌──────────────────┐
│ Update status    │  "classified" → "under_review"
│ in audit log     │
└──────┬───────────┘
       │
       ▼
┌──────────────────┐
│ Log appeal       │  appeal_reason, appeal_timestamp
│ reason + ts      │
└──────┬───────────┘
       │
       ▼
    JSON Response
    { submission_id, status: "under_review", message: "..." }
```

## Detection Signals

### Signal 1: LLM-Based Classification (Groq)

- **What it measures**: Semantic coherence, stylistic naturalness, and authorial voice at a conceptual level. The LLM reads the text holistically and assesses whether it "feels" like human writing — considering tone consistency, emotional depth, narrative logic, and idiosyncratic phrasing.
- **Why it differs between human and AI**: LLMs are trained to recognize their own output patterns. AI-generated text tends toward a smoothed-out, unerringly coherent style without the natural digressions, inconsistencies, and personal voice markers that human writing carries. An LLM can detect these "too-perfect" qualities.
- **Output format**: A float `score` from 0.0 to 1.0 (0 = definitely AI, 1 = definitely human), and a `reason` string explaining the assessment.
- **Blind spots**:
  - Formal, structured writing (academic papers, technical docs) can be misread as AI-generated because it naturally lacks conversational idiosyncrasy.
  - Non-native English text may appear "unnatural" to the model and score as AI.
  - Adversarial prompting — AI output specifically instructed to "write like a human, with typos and digressions" — can fool this signal.
  - Very short texts (<100 words) give the model too little context to make a reliable judgment.
  - Model is itself an LLM, so it may have a bias toward labeling borderline cases as AI (self-recognition bias).

### Signal 2: Stylometric Heuristics

- **What it measures**: Four measurable statistical properties of the text's structure:
  1. **Type-Token Ratio (TTR)**: `unique_words / total_words`. Measures vocabulary diversity. AI writing tends to reuse the same vocabulary; human writers draw from a broader, more varied lexicon.
  2. **Sentence Length Coefficient of Variation (CV)**: `stdev(sentence_lengths) / mean(sentence_lengths)`. Measures structural variability. Human writing has unpredictable sentence rhythms; AI tends toward uniform sentence lengths.
  3. **Punctuation Variety Density**: A composite of punctuation character frequency and diversity (`unique_punctuation_types / len(text)`). Human writing uses more varied punctuation (em-dashes, semicolons, ellipses); AI defaults to periods and commas.
  4. **Hapax Legomena Ratio**: `words_appearing_once / total_words`. A high ratio indicates creative, non-repetitive word choice (human-like); a low ratio suggests a smaller active vocabulary (AI-like).
- **Why it differs between human and AI**: These are all measures of **variability**. Human writing, across most genres, is inherently messier and more variable than AI-generated text. LLMs are optimized to produce "good" writing, which statistically means uniform, well-structured, and lexically repetitive output. Human writers, even skilled ones, show more variance in all four dimensions.
- **Output format**: A float `score` from 0.0 to 1.0 (0 = AI-like uniformity, 1 = human-like variability), and a `detail` dictionary containing the raw and normalized values for each sub-metric.
- **Blind spots**:
  - Highly stylized poetry that uses intentional repetition and simple vocabulary (haiku, minimalist poetry) will score as AI-like on TTR and hapax legomena.
  - Technical writing, documentation, or formal reports with naturally uniform sentence structures will skew toward AI on CV.
  - Very short texts (<50 words) don't contain enough data for meaningful statistical measures.
  - Authors with a naturally repetitive style (deliberate parallelism, refrains) may be misclassified.
  - Code or non-prose text will break the sentence-splitting logic entirely.

The two signals are genuinely complementary: one is **semantic/conceptual** (the LLM "reads" the text), the other is **structural/statistical** (it measures the text). One can catch what the other misses, and their disagreement produces useful uncertainty.

## Confidence Scoring with Uncertainty

### Score Meaning

A confidence score of `x` means: "this system estimates there is an `x` probability that this text was written by a human." Or equivalently: "on a 0–1 scale where 1 means definitely human and 0 means definitely AI, this is where the text lands."

A score of 0.51 is meaningfully different from 0.95 because:
- **0.51** falls in the "uncertain" middle band (0.4–0.6) — neither signal is confident, or they disagree. The transparency label will tell the reader "we don't know." This is an honest admission of uncertainty.
- **0.95** is well into "high-confidence human" territory (>0.6) — both signals strongly agree the text is human-written. The transparency label will tell the reader "this is almost certainly human-made."

The middle band (0.4–0.6) is intentionally wide — it reflects the reality that many texts fall into a gray area where no system can be certain. Rather than forcing a binary call on borderline cases, Provenance Guard admits uncertainty.

### How Raw Signals Are Combined

Each signal independently produces a score from 0.0–1.0. The combined score is a weighted average:

```
combined_score = (0.6 * llm_score) + (0.4 * heuristics_score)
```

The LLM signal receives 60% weight because:
- It captures semantic meaning, which is the strongest differentiator between human and AI writing.
- Stylometrics can be thrown off by genre conventions (poetry, technical writing), so it serves as a moderating influence rather than the primary signal.

The 40% heuristics weight ensures structural evidence can:
- **Reinforce** a strong LLM score (e.g., LLM says 0.9 human, heuristics says 0.85 human → combined 0.88 — high-confidence human).
- **Introduce doubt** on an overconfident LLM score (e.g., LLM says 0.95 human, heuristics says 0.3 human → combined 0.69 — still human, but closer to the uncertain boundary).
- **Sway a borderline** case (e.g., LLM says 0.5, heuristics says 0.2 → combined 0.38 — just inside the AI band).

### Why This Is Meaningful (Testing Approach)

Validation approach (to be implemented in code):
1. **Known-human corpus**: Run a set of publicly available human-written texts (Project Gutenberg excerpts, blog posts, student essays) through the system. A well-calibrated detector should score human texts above 0.6 on average.
2. **Known-AI corpus**: Run a set of texts generated by popular LLMs (ChatGPT, Claude, Groq) through the system. These should score below 0.4 on average.
3. **Disagreement cases**: Identify texts where the two signals disagree by more than 0.3. These are the "hard cases" that should land in the uncertain band. Verify that the combined score is between 0.4 and 0.6 for these.
4. **Calibration check**: For any text, the score should not be arbitrarily precise. Scores like 0.49 and 0.51 should produce different labels — that's by design, because they land on opposite sides of the 0.5 line. But the label text for 0.49 (just-barely-AI) should acknowledge the closeness, while the label for 0.15 (solidly AI) should project confidence.

## Transparency Label Design

Each label variant is a plain-language message designed to be shown alongside content on a creative sharing platform. The labels communicate the result honestly without passing definitive judgment on the creator.

### High-Confidence AI (combined_score < 0.4)

> **AI-Generated / Likely AI**
>
> Our automated detection system found strong indicators that this content may have been generated by AI rather than written by a human. Multiple analysis signals — including writing style patterns and text structure — suggest AI authorship. This label reflects our system's assessment, not a final determination. The creator may contest this classification.

### Uncertain (0.4 <= combined_score <= 0.6)

> **Uncertain Attribution**
>
> Our system couldn't determine with confidence whether this content was written by a human or generated by AI. The writing shows a mix of patterns — some characteristic of human authorship, some of AI generation. We display this label transparently rather than guessing. The creator may contest this classification.

### High-Confidence Human (combined_score > 0.6)

> **Human-Written / Likely Human**
>
> Our automated detection system found strong indicators that this content was written by a human. Multiple analysis signals — including vocabulary diversity, sentence rhythm, and stylistic patterns — suggest human authorship. This label reflects our system's assessment, not a guarantee. While we are confident in this result, no automated system is perfect.

## Appeals Workflow

### Who Can Submit an Appeal

Any creator who believes their content was misclassified. The appeal endpoint is public — there is no authentication in this version. The creator identifies their submission by the `submission_id` returned in the original `/submit` response.

### What Information They Provide

1. `submission_id` — the ID returned by the original submission.
2. `reason` — a free-text explanation of why they believe the classification is incorrect (e.g., "This is my original poetry; I use intentional repetition as a stylistic device").

### System Behavior on Appeal

1. The system looks up the submission in the audit log.
   - If the ID doesn't exist → HTTP 404, "Submission not found."
   - If an appeal already exists for this submission → HTTP 409, "An appeal has already been filed for this submission."
2. If valid, the system:
   - Updates the submission's `status` from `classified` to `under_review`.
   - Records `appeal_reason` and `appeal_timestamp` in the audit log entry.
   - Returns HTTP 200 with a confirmation message.

### What a Human Reviewer Would See in the Appeal Queue

A reviewer querying the audit log for `status = under_review` entries would see:
- The original text (or its hash).
- Both individual signal scores and their detailed reasoning.
- The combined confidence score.
- The label that was originally shown.
- The creator's appeal reason.
- The timestamp of both the original classification and the appeal.

This gives the reviewer everything needed to make a manual determination.

## API Surface

### `POST /submit`
**Request**: `{ "content": "<text to classify>" }`
**Response** (200):
```json
{
  "submission_id": "uuid-string",
  "attribution": "ai" | "human" | "uncertain",
  "confidence": 0.0-1.0,
  "label_variant": "ai" | "human" | "uncertain",
  "label_text": "The full plain-language transparency label text",
  "signals": {
    "llm": {
      "score": 0.0-1.0,
      "reason": "Explanation from the LLM"
    },
    "heuristics": {
      "score": 0.0-1.0,
      "detail": {
        "ttr": 0.0-1.0,
        "sentence_length_cv": 0.0-1.0,
        "punctuation_variety": 0.0-1.0,
        "hapax_ratio": 0.0-1.0
      }
    }
  }
}
```
**Errors**: 400 (invalid/missing content), 429 (rate limited)

### `POST /appeal`
**Request**: `{ "submission_id": "uuid", "reason": "Explanation text" }`
**Response** (200):
```json
{
  "submission_id": "uuid",
  "status": "under_review",
  "message": "Appeal received. This submission is now under review."
}
```
**Errors**: 400 (missing fields), 404 (submission not found), 409 (already appealed)

### `GET /log`
**Response** (200):
```json
{
  "entries": [
    {
      "submission_id": "uuid",
      "timestamp": "ISO 8601",
      "content_hash": "sha256 hex",
      "content_length": 1234,
      "llm_score": 0.85,
      "llm_reason": "...",
      "heuristics_score": 0.72,
      "heuristics_detail": { ... },
      "combined_score": 0.80,
      "attribution": "human",
      "label_text": "...",
      "status": "classified" | "under_review",
      "appeal_reason": null,
      "appeal_timestamp": null
    }
  ],
  "count": 1
}
```

### `GET /health`
**Response** (200): `{ "status": "ok" }`

## Anticipated Edge Cases

### 1. Minimalist Poetry / Intentional Repetition
A poem using heavy repetition, simple vocabulary, and short uniform lines (e.g., haiku, list poems, villanelles) will almost certainly score low on TTR, sentence length CV, and hapax ratio. The heuristics signal will strongly indicate "AI-generated." If the LLM signal is also uncertain (because the poem is abstract/surreal), the combined score will land in the uncertain or even AI band. This is a false positive waiting to happen — and precisely the kind of case the appeals workflow exists for.

### 2. Technical Documentation / Formal Writing
A well-structured technical tutorial, API documentation page, or academic abstract will show low sentence length variance, specialized but repetitive vocabulary, and predictable punctuation patterns. Both signals may flag it as AI-generated. The LLM signal is especially vulnerable here because formal writing "feels" AI-like. The system needs to handle this without mislabeling legitimate technical content.

### 3. Very Short Submissions
Texts under 100 words give the LLM too little context and the heuristics too few data points. TTR becomes unstable with small sample sizes. The system should not attempt to classify extremely short texts with any confidence — it should either reject them or explicitly flag low-confidence results.

### 4. Mixed Human-AI Content
A human writer who uses AI to generate a paragraph and then edits it, or who intersperses AI-generated sections with their own writing. Both signals will struggle because the text is genuinely neither fully human nor fully AI. The combined score will likely land in the uncertain band, which is the honest answer.

### 5. Non-English or Code-Heavy Text
The stylometric heuristics use English-centric assumptions (sentence splitting by punctuation, word tokenization by spaces). Non-English languages or code blocks will break these assumptions. The LLM signal may handle this better, but non-English text is out of the training distribution focus.

## Rate Limiting Design

| Endpoint   | Limit             | Reasoning |
|------------|-------------------|-----------|
| `/submit`  | 10 per minute per IP | The Groq free tier has usage limits (~30 RPM). 10 RPM per client allows 3 concurrent users at peak before hitting the Groq cap, with headroom for retries and testing. A creative platform would see bursts but not sustained high throughput from individual users. |
| `/appeal`  | 3 per minute per IP  | Appeals should be rare and deliberate. A low cap prevents spam while allowing legitimate use. |
| `/log`     | 30 per minute per IP | Read-only endpoint, harmless but still rate-limited to prevent log scraping at volume. |

## Audit Log Design

The audit log is a SQLite database (`audit.db`) with a single table:

```sql
CREATE TABLE audit_log (
    submission_id TEXT PRIMARY KEY,
    timestamp TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    content_length INTEGER NOT NULL,
    llm_score REAL NOT NULL,
    llm_reason TEXT NOT NULL,
    heuristics_score REAL NOT NULL,
    heuristics_detail TEXT NOT NULL,  -- JSON blob
    combined_score REAL NOT NULL,
    attribution TEXT NOT NULL,  -- "ai" | "human" | "uncertain"
    label_text TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT "classified",
    appeal_reason TEXT,
    appeal_timestamp TEXT,
    user_ip TEXT
);
```

Every `/submit` results in one INSERT. Every `/appeal` results in one UPDATE (setting `status`, `appeal_reason`, `appeal_timestamp`). The `GET /log` endpoint reads entries ordered by timestamp descending.

## AI Tool Plan

For each implementation milestone, this section specifies which parts of this spec to feed into an AI code generation tool, what to ask for, and how to verify correctness before moving on.

### M3: Submission Endpoint + First Signal (Groq LLM)

**Spec sections to provide to the AI tool:**
- Architecture Diagram (submission flow, steps from Client through Signal 1)
- Architecture Narrative (points 1–4: submission flow through LLM classification)
- Detection Signals → Signal 1: LLM-Based Classification (what it measures, output format, Groq model to use)
- API Surface → `POST /submit` (request shape, response shape)
- Rate Limiting Design (limits for `/submit`)

**What to ask the AI to generate:**
1. A Flask application skeleton (`main.py`) with the app factory, Flask-Limiter wired to the `/submit` endpoint (10/minute/IP), and a `GET /health` endpoint.
2. A Groq LLM classifier function (`signals/llm_classifier.py`) that takes raw text, sends it to `llama-3.3-70b-versatile` via the Groq SDK, and returns a `(score: float, reason: str)` tuple. The prompt must instruct the model to output JSON with a `score` (0.0 = definitely AI, 1.0 = definitely human) and `reason` (brief explanation). The function must handle API errors gracefully (return a fallback score of 0.5 with an error message as reason).
3. The `POST /submit` endpoint wired to the LLM classifier only — validates input (non-empty string, min 50 chars), calls the Groq classifier, generates a UUID submission ID, computes `attribution` from the LLM score alone using the thresholds (`< 0.4 → ai`, `0.4–0.6 → uncertain`, `> 0.6 → human`), and returns the structured JSON response. Other signals fields are omitted or set to `null` for now.

**How to verify the output:**
1. Start the Flask dev server. `curl -X POST /submit -H "Content-Type: application/json" -d '{"content": "Short test."}'` — should return 400 (below 50 chars).
2. `curl -X POST /submit -d '{}'` — should return 400 (missing content field).
3. Submit a clearly AI-generated paragraph (e.g., something from ChatGPT: "In today's rapidly evolving technological landscape, it is imperative that organizations leverage synergies to optimize workflows..."). The response should have `llm.score < 0.5` and `attribution` either `ai` or `uncertain`.
4. Submit a clearly human-written paragraph (e.g., a personal anecdote with digressions, unusual word choices, emotional tone shifts). The response should have `llm.score > 0.5` and `attribution` either `human` or `uncertain`.
5. Verify the JSON response matches the API Surface shape: contains `submission_id` (UUID string), `attribution` (one of three strings), `confidence`, `signals.llm.score`, `signals.llm.reason`.
6. Hit the endpoint 11 times in rapid succession — the 11th request should return 429.
7. `curl GET /health` returns `{ "status": "ok" }`.

### M4: Second Signal + Confidence Scoring

**Spec sections to provide to the AI tool:**
- Architecture Diagram (submission flow through Confidence Scorer)
- Detection Signals → Signal 2: Stylometric Heuristics (all four sub-metrics, output format, blind spots)
- Confidence Scoring with Uncertainty (weighted combination formula, thresholds, what scores mean)
- Architecture Narrative (points 5–6: heuristics computation and scoring combination)

**What to ask the AI to generate:**
1. A stylometric heuristics module (`signals/stylometry.py`) that takes raw text and returns a `(score: float, detail: dict)` tuple. The module must:
   - Split text into sentences (by `.`, `!`, `?`; handle edge cases like `...` and `Mr.`).
   - Tokenize words (by whitespace; strip punctuation for TTR but count it for punctuation variety).
   - Compute TTR: `len(set(words)) / len(words)`, normalized via a sigmoid center around 0.55 (human average) so that 0.55 maps to 0.5 on the normalized scale.
   - Compute Sentence Length CV: `stdev(sentence_lengths) / mean(sentence_lengths)`, normalized via a sigmoid center around 0.5 (0.5 maps to 0.5).
   - Compute Punctuation Variety Density: count distinct punctuation chars (`.,;:!?—-"()…`), divide by text length, normalize similarly.
   - Compute Hapax Legomena Ratio: `len(words_appearing_once) / len(words)`, normalize.
   - Average the four normalized sub-scores into a single `score` (0–1) and return it with a `detail` dict containing each sub-score.
   - Handle edge cases: empty text returns (0.5, all 0.5 details), single-sentence text has CV = 0.
2. A confidence scorer module (`signals/scorer.py`) that takes `(llm_score, heuristics_score)` and returns `(combined_score, attribution, label_text)`:
   - `combined_score = 0.6 * llm_score + 0.4 * heuristics_score` (rounded to 2 decimal places).
   - `attribution` = `"ai"` if combined < 0.4, `"uncertain"` if 0.4–0.6, `"human"` if > 0.6.
   - `label_text` = the appropriate pre-written variant string from Transparency Label Design.
3. Wired into `POST /submit` so both signals are called (ideally the LLM call and heuristics computation run in parallel or sequentially — both are fine for this project), combined through the scorer, and the response includes both signal scores and details.

**How to verify the output:**
1. Submit a clearly AI-generated text to the endpoint. Confirm `heuristics.score < 0.4` (uniform sentence lengths, low TTR, low hapax). Confirm `combined_score` equals `0.6 * llm.score + 0.4 * heuristics.score` (do the math manually on the response values).
2. Submit a clearly human-written text (e.g., a personal blog post with varied sentence lengths and diverse vocabulary). Confirm `heuristics.score > 0.6`.
3. Submit a minimalist poem (short, repetitive, simple vocabulary) — the heuristics score should be low (< 0.4) even if the LLM score is higher. This is the disagreement case. Verify the combined score reflects the tension between the two signals.
4. Check the `heuristics_detail` in the response contains all four sub-keys (`ttr`, `sentence_length_cv`, `punctuation_variety`, `hapax_ratio`), each between 0.0 and 1.0.
5. Confirm the `attribution` field correctly maps from the combined score thresholds (test cases at ~0.2, ~0.5, ~0.8).
6. Verify that the response shape now includes `signals.llm` (score + reason) AND `signals.heuristics` (score + detail).

### M5: Production Layer (Labels, Appeals, Audit Log, Rate Limiting)

**Spec sections to provide to the AI tool:**
- Architecture Diagram (both submission and appeal flows, full pipeline)
- Transparency Label Design (all three variant texts verbatim)
- Appeals Workflow (who can appeal, what they provide, system behavior, status transitions, reviewer view)
- Audit Log Design (SQLite schema, INSERT/UPDATE behavior)
- Rate Limiting Design (all four endpoint limits)
- API Surface (`POST /appeal`, `GET /log`, `GET /health` request/response shapes)
- Architecture Narrative (full flow, points 7–9: label generation, audit logging, response)

**What to ask the AI to generate:**
1. A transparency label generator (`labels.py`) that takes `(combined_score, attribution)` and returns the pre-written label text string for the appropriate variant. The label text must match the verbatim strings from the Transparency Label Design section exactly.
2. An audit log module (`audit.py`) that:
   - Creates the SQLite database and table on first use (schema from Audit Log Design).
   - Provides `log_submission(...)` that INSERTs a row on every `/submit` call with all classification fields.
   - Provides `log_appeal(submission_id, appeal_reason)` that UPDATEs the row — sets `status = "under_review"`, `appeal_reason`, `appeal_timestamp`. Returns `True` on success, `False` on not-found.
   - Provides `get_log(limit=20)` that SELECTs rows ordered by timestamp DESC.
   - Provides `submission_exists(submission_id)` for the appeal validation check.
   - Provides `has_appeal(submission_id)` for the 409 check.
3. The `POST /appeal` endpoint (wired with Flask-Limiter at 3/minute/IP):
   - Validates `submission_id` and `reason` are present (400 if missing).
   - Checks existence (404 if not found).
   - Checks for existing appeal (409 if already appealed).
   - Calls `log_appeal`, returns confirmation.
4. The `GET /log` endpoint (wired at 30/minute/IP):
   - Accepts optional `?limit=N` query parameter (default 20, max 100).
   - Returns entries with count.
   - Each entry must include all audit fields in the response JSON.
5. Wire the label generator and audit logger into `POST /submit` so every submission produces a label and writes to the audit log.
6. Ensure Flask-Limiter is configured for all four endpoints with the correct limits.
7. Load `GROQ_API_KEY` from environment via `python-dotenv` so the server starts cleanly with a `.env` file.

**How to verify the output:**
1. **Label variants reachable**: Submit three texts expected to score in different bands — one clearly AI (should get the AI label variant), one clearly human (should get the human label variant), one intentionally ambiguous like a repetitive poem (should get the uncertain label variant). Confirm each response's `label_text` field contains the exact verbatim text from planning.md.
2. **Appeal happy path**: Submit a text, note the `submission_id`. POST to `/appeal` with that ID and a reason. Response should be 200 with `status: "under_review"`. Call `GET /log` — the entry for that submission should now have `status: "under_review"`, `appeal_reason` populated, and `appeal_timestamp` populated.
3. **Appeal error cases**:
   - POST `/appeal` with a made-up UUID → 404.
   - POST `/appeal` with the same real ID twice → second call returns 409.
   - POST `/appeal` with missing `reason` field → 400.
4. **Audit log completeness**: Call `GET /log` after a few submissions. Verify entries are ordered by timestamp descending. Pick one entry and confirm it has all fields: `submission_id`, `timestamp`, `content_hash`, `content_length`, `llm_score`, `llm_reason`, `heuristics_score`, `heuristics_detail` (a dict with 4 sub-keys), `combined_score`, `attribution`, `label_text`, `status`, `appeal_reason`, `appeal_timestamp`.
5. **Rate limiting on all endpoints**: Hit `/submit` 11 times quickly → 429. Hit `/appeal` 4 times quickly → 429. Hit `/log` 31 times quickly → 429. Confirm the 429 response body includes a retry-after indication.
6. **Content hash**: Submit the same text twice. Confirm the two entries have different `submission_id` values but the same `content_hash` in the audit log.
7. **End-to-end appeal audit trail**: Submit → appeal → GET /log. The log entry should show the original classification fields intact plus `appeal_reason` and `appeal_timestamp` populated. Nothing about the original classification should be overwritten by the appeal — the appeal adds to the record, it doesn't replace the decision.
