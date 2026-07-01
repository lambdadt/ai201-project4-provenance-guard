#!/usr/bin/env bash
set -euo pipefail

BASE="http://127.0.0.1:5000"
PASS="\033[0;32mPASS\033[0m"
FAIL="\033[0;31mFAIL\033[0m"
SEP="----------------------------------------"

result() {
    if [ "$1" = "pass" ]; then
        printf "  Result: $PASS\n"
    else
        printf "  Result: $FAIL\n"
    fi
}

echo "=== M3 Verification: Submission Endpoint + Groq LLM Signal + Audit Log ==="
echo ""

# ── Test 1: Health ──
echo "$SEP"
echo "Test 1: GET /health"
echo "$SEP"
RESP=$(curl -s "$BASE/health")
echo "  Expected: {\"status\":\"ok\"}"
echo "  Got:      $RESP"
if echo "$RESP" | grep -q '"ok"'; then result pass; else result fail; fi
echo ""

# ── Test 2: Missing text field ──
echo "$SEP"
echo "Test 2: POST /submit with missing 'text' field"
echo "$SEP"
RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d '{}')
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/submit" -H "Content-Type: application/json" -d '{}')
echo "  Expected: 400"
echo "  Got:      $CODE"
echo "  Body:     $RESP"
if [ "$CODE" = "400" ]; then result pass; else result fail; fi
echo ""

# ── Test 3: Missing creator_id ──
echo "$SEP"
echo "Test 3: POST /submit with missing 'creator_id' field"
echo "$SEP"
PAYLOAD='{"text": "This text is long enough to pass the minimum character length check easily now without any issues."}'
RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "  Expected: 400"
echo "  Got:      $CODE"
echo "  Body:     $RESP"
if [ "$CODE" = "400" ]; then result pass; else result fail; fi
echo ""

# ── Test 4: Text too short ──
echo "$SEP"
echo "Test 4: POST /submit with text < 50 chars"
echo "$SEP"
PAYLOAD='{"text": "Hello world", "creator_id": "test-user-1"}'
RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "  Expected: 400, error about minimum length"
echo "  Got:      $CODE"
echo "  Body:     $RESP"
if [ "$CODE" = "400" ]; then result pass; else result fail; fi
echo ""

# ── Test 5: AI-generated text ──
echo "$SEP"
echo "Test 5: Clearly AI-generated text (corporate jargon)"
echo "$SEP"
PAYLOAD=$(python3 -c '
import json
text = "In todays rapidly evolving digital landscape organizations must leverage synergistic methodologies to optimize cross-functional workflows and drive scalable innovation across enterprise ecosystems. By implementing best-in-class solutions teams can maximize operational efficiency while maintaining alignment with strategic objectives."
print(json.dumps({"text": text, "creator_id": "test-user-2"}))
')
RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "  Response:"
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
LLM_SCORE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "parse_error")
echo ""
echo "  Expected: llm.score < 0.5, attribution = 'ai' or 'uncertain'"
echo "  Got:      llm.score = $LLM_SCORE, attribution = $ATTRIBUTION"
if [ "$LLM_SCORE" != "parse_error" ] && python3 -c "exit(0 if float('$LLM_SCORE') < 0.5 else 1)" 2>/dev/null; then
    result pass
elif [ "$ATTRIBUTION" = "uncertain" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 6: Human-written text ──
echo "$SEP"
echo "Test 6: Clearly human-written text (personal anecdote)"
echo "$SEP"
PAYLOAD=$(python3 -c '
import json
text = "I walked down to the corner store last night around midnight, not because I needed anything in particular but just because I could not sleep. The guy behind the counter, Sameer, he looked up from his phone and gave me this tired little nod like he understood completely why anyone would be buying a bag of chips at that hour. We ended up talking about his daughters soccer game for like twenty minutes. She scored a goal, apparently, and the way his face lit up - man, you could not fake that kind of pride if you tried. I walked home feeling oddly better about the world."
print(json.dumps({"text": text, "creator_id": "test-user-3"}))
')
RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
echo "  Response:"
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
LLM_SCORE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "parse_error")
echo ""
echo "  Expected: llm.score > 0.5, attribution = 'human' or 'uncertain'"
echo "  Got:      llm.score = $LLM_SCORE, attribution = $ATTRIBUTION"
if [ "$LLM_SCORE" != "parse_error" ] && python3 -c "exit(0 if float('$LLM_SCORE') > 0.5 else 1)" 2>/dev/null; then
    result pass
elif [ "$ATTRIBUTION" = "uncertain" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 7: Response shape validation ──
echo "$SEP"
echo "Test 7: Response contains all required keys (content_id, attribution, confidence, label, signals)"
echo "$SEP"
PAYLOAD='{"text": "This is a test sentence that is definitely long enough to meet the minimum character requirement for the submission endpoint checking shape.", "creator_id": "test-user-4"}'
RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$PAYLOAD")
REQUIRED_KEYS=("content_id" "attribution" "confidence" "label")
ALL_OK=true
for key in "${REQUIRED_KEYS[@]}"; do
    if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); _ = d['$key']" 2>/dev/null; then
        VAL=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$key'])" 2>/dev/null)
        echo "  [$key]: $VAL"
    else
        echo "  [$key]: MISSING"
        ALL_OK=false
    fi
done
# Check nested signals
for subkey in "score" "reason"; do
    key_name="signals.llm.$subkey"
    if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); _ = d['signals']['llm']['$subkey']" 2>/dev/null; then
        VAL=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['$subkey'])" 2>/dev/null)
        echo "  [$key_name]: $VAL"
    else
        echo "  [$key_name]: MISSING"
        ALL_OK=false
    fi
done
# Check heuristics is null
HEUR_NULL=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals'].get('heuristics'))" 2>/dev/null || echo "missing")
echo "  [signals.heuristics]: $HEUR_NULL (expected: None/null)"
# Check attribution is valid
ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null)
if [ "$ATTRIBUTION" != "ai" ] && [ "$ATTRIBUTION" != "human" ] && [ "$ATTRIBUTION" != "uncertain" ]; then
    echo "  [attribution]: invalid value '$ATTRIBUTION'"
    ALL_OK=false
fi
if [ "$ALL_OK" = "true" ] && [ "$HEUR_NULL" = "None" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 8: Rate limiting ──
echo "$SEP"
echo "Test 8: Rate limiting — 11 rapid /submit requests"
echo "$SEP"
echo "  Waiting 60 seconds for rate limit window to reset..."
sleep 60
echo "  Expected: first 10 return 200, 11th returns 429"
BODY='{"text": "This is a test text that is long enough to pass the minimum character requirement valid valid valid valid valid valid content.", "creator_id": "rate-test-user"}'
HAD_429=false
for i in $(seq 1 11); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$BODY")
    printf "  Request %2d: %s" "$i" "$CODE"
    if [ "$CODE" = "429" ]; then
        echo "  (rate limited)"
        HAD_429=true
    else
        echo ""
    fi
done
if [ "$HAD_429" = "true" ]; then result pass; else result fail; fi
echo ""

# ── Test 9: GET /log shows audit entries ──
echo "$SEP"
echo "Test 9: GET /log returns audit log entries"
echo "$SEP"
RESP=$(curl -s "$BASE/log")
COUNT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['count'])" 2>/dev/null || echo "0")
echo "  Entry count: $COUNT"
echo "  Expected: at least 3 entries from test submissions above"
echo "  Sample entry:"
echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d['entries']:
    e = d['entries'][0]
    print(f\"    content_id:    {e.get('content_id')}\")
    print(f\"    creator_id:    {e.get('creator_id')}\")
    print(f\"    timestamp:     {e.get('timestamp')}\")
    print(f\"    attribution:   {e.get('attribution')}\")
    print(f\"    confidence:    {e.get('confidence')}\")
    print(f\"    llm_score:     {e.get('llm_score')}\")
    print(f\"    llm_reason:    {e.get('llm_reason', '')[:80]}...\")
    print(f\"    status:        {e.get('status')}\")
" 2>/dev/null || echo "  (could not parse log entry)"
echo ""
if [ "$COUNT" -ge 3 ]; then result pass; else result fail; fi
echo ""

echo "=== All M3 tests complete ==="
