import json

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

from audit import init_db, log_submission, get_log, submission_exists, has_appeal, log_appeal
from labels import get_label
from signals.llm_classifier import classify_text
from signals.scorer import compute_combined_score
from signals.stylometry import analyze_text

load_dotenv()

app = Flask(__name__)

limiter = Limiter(
    get_remote_address,
    app=app,
    default_limits=[],
    storage_uri="memory://",
)

MIN_CONTENT_LENGTH = 50


@app.route("/health", methods=["GET"])
@limiter.limit("60 per minute")
def health():
    return jsonify({"status": "ok"})


@app.route("/submit", methods=["POST"])
@limiter.limit("10 per minute")
def submit():
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Request body must be valid JSON"}), 400

    text = data.get("text")
    if not text or not isinstance(text, str) or not text.strip():
        return jsonify({"error": "Field 'text' is required and must be a non-empty string"}), 400
    text = text.strip()

    if len(text) < MIN_CONTENT_LENGTH:
        return jsonify({
            "error": f"Content must be at least {MIN_CONTENT_LENGTH} characters (received {len(text)})"
        }), 400

    creator_id = data.get("creator_id")
    if not creator_id or not isinstance(creator_id, str) or not creator_id.strip():
        return jsonify({"error": "Field 'creator_id' is required and must be a non-empty string"}), 400
    creator_id = creator_id.strip()

    llm_score, llm_reason = classify_text(text)
    heuristics_score, heuristics_detail = analyze_text(text)
    confidence, attribution = compute_combined_score(llm_score, heuristics_score)

    content_id = log_submission(
        creator_id=creator_id,
        attribution=attribution,
        confidence=confidence,
        llm_score=round(llm_score, 2),
        llm_reason=llm_reason,
        heuristics_score=heuristics_score,
        heuristics_detail=json.dumps(heuristics_detail),
    )

    return jsonify({
        "content_id": content_id,
        "attribution": attribution,
        "confidence": confidence,
        "label": get_label(attribution),
        "signals": {
            "llm": {
                "score": round(llm_score, 2),
                "reason": llm_reason,
            },
            "heuristics": {
                "score": heuristics_score,
                "detail": heuristics_detail,
            },
        },
    })


@app.route("/log", methods=["GET"])
@limiter.limit("30 per minute")
def log():
    try:
        limit = int(request.args.get("limit", 20))
    except ValueError:
        limit = 20
    limit = max(1, min(limit, 100))
    entries = get_log(limit=limit)
    return jsonify({"entries": entries, "count": len(entries)})


@app.route("/appeal", methods=["POST"])
@limiter.limit("3 per minute")
def appeal():
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Request body must be valid JSON"}), 400

    content_id = data.get("content_id")
    if not content_id or not isinstance(content_id, str) or not content_id.strip():
        return jsonify({"error": "Field 'content_id' is required and must be a non-empty string"}), 400
    content_id = content_id.strip()

    creator_reasoning = data.get("creator_reasoning")
    if not creator_reasoning or not isinstance(creator_reasoning, str) or not creator_reasoning.strip():
        return jsonify({"error": "Field 'creator_reasoning' is required and must be a non-empty string"}), 400
    creator_reasoning = creator_reasoning.strip()

    if not submission_exists(content_id):
        return jsonify({"error": "Submission not found"}), 404

    if has_appeal(content_id):
        return jsonify({"error": "An appeal has already been filed for this submission"}), 409

    log_appeal(content_id, creator_reasoning)

    return jsonify({
        "content_id": content_id,
        "status": "under_review",
        "message": "Appeal received. This submission is now under review.",
    })


if __name__ == "__main__":
    init_db()
    app.run(debug=True)
