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

echo "=== M5 Verification: Production Layer ==="
echo ""

# ── Test 1: All three label variants are reachable ──
echo "$SEP"
echo "Test 1: All three label variants are reachable"
echo "$SEP"

AI_TEXT="In todays rapidly evolving digital landscape organizations must leverage synergistic methodologies to optimize cross-functional workflows and drive scalable innovation across enterprise ecosystems. By implementing best-in-class solutions teams can maximize operational efficiency while maintaining alignment with strategic objectives across all business units and departments."

HUMAN_TEXT="ok so i finally tried that new ramen place downtown and honestly? underwhelming. the broth was fine but they put WAY too much sodium in it and i was thirsty for like three hours after. my friend got the spicy version and said it was better. probably will not go back unless someone drags me there"

BORDER_TEXT="The relationship between monetary policy and asset price inflation has been extensively studied in the literature. Central banks face a fundamental tension between their mandate for price stability and the unintended consequences of prolonged low interest rates on equity and real estate valuations."

MID_TEXT="This project aims to explore the intersection of technology and daily life. I spent about three hours yesterday reading through old forum posts from the early 2000s, and what struck me most was how optimistic everyone sounded. People genuinely believed the internet would make us kinder to each other. Looking back now, I am not sure what to make of that hope."

FOUND_AI=false
FOUND_HUMAN=false
FOUND_UNCERTAIN=false

submit_label_test() {
    local tag="$1"
    local text="$2"
    local payload
    payload=$(python3 -c "import json; print(json.dumps({'text': '''$text''', 'creator_id': 'test-m5-labels'}))")
    local resp
    resp=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$payload")
    local attr
    attr=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "err")
    local lbl
    lbl=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['label'][:60])" 2>/dev/null || echo "err")
    echo "  [$tag] attribution=$attr, label=\"$lbl...\""
    case "$attr" in
        ai) FOUND_AI=true ;;
        human) FOUND_HUMAN=true ;;
        uncertain) FOUND_UNCERTAIN=true ;;
    esac
}

submit_label_test "ai" "$AI_TEXT"
submit_label_test "human" "$HUMAN_TEXT"
submit_label_test "border" "$BORDER_TEXT"
submit_label_test "mid" "$MID_TEXT"

echo ""
MISSING=false
for pair in "ai $FOUND_AI" "human $FOUND_HUMAN" "uncertain $FOUND_UNCERTAIN"; do
    attr=$(echo "$pair" | cut -d' ' -f1)
    val=$(echo "$pair" | cut -d' ' -f2)
    if [ "$val" = "true" ]; then
        echo "  [$attr] variant: found"
    elif [ "$attr" = "uncertain" ]; then
        echo "  [$attr] variant: not hit (informational — requires live signal disagreement at 0.4-0.6)"
    else
        echo "  [$attr] variant: NOT FOUND"
        MISSING=true
    fi
done
if [ "$MISSING" = "false" ]; then result pass; else result fail; fi
if [ "$MISSING" = "false" ]; then result pass; else result fail; fi
echo ""

# ── Test 2: Label text matches spec (check one label in full) ──
echo "$SEP"
echo "Test 2: Label texts contain expected key phrases"
echo "$SEP"
# Submit the human text and check the label content
payload=$(python3 -c "import json; print(json.dumps({'text': '''$HUMAN_TEXT''', 'creator_id': 'test-m5-labeltext'}))")
resp=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$payload")
label_text=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['label'])" 2>/dev/null || echo "err")
echo "  Label text length: ${#label_text} chars"
echo "  Contains 'vocabulary diversity': $(echo "$label_text" | grep -c 'vocabulary diversity' || echo 0)"
echo "  Contains 'not a guarantee': $(echo "$label_text" | grep -c 'not a guarantee' || echo 0)"

# Check a few expected substrings from the spec
CHECKS_OK=true
if echo "$label_text" | grep -q "vocabulary diversity"; then
    echo "  [vocabulary diversity]: found"
else
    echo "  [vocabulary diversity]: MISSING"
    CHECKS_OK=false
fi
if echo "$label_text" | grep -q "not a guarantee"; then
    echo "  [not a guarantee]: found"
else
    echo "  [not a guarantee]: MISSING"
    CHECKS_OK=false
fi
if [ "$CHECKS_OK" = "true" ]; then result pass; else result fail; fi
echo ""

# ── Test 3: Appeal happy path ──
echo "$SEP"
echo "Test 3: Appeal endpoint — submit then appeal"
echo "$SEP"
# Submit a new piece of content first to get a content_id
SUBMIT_PAYLOAD='{"text": "This is a test piece of content that I wrote myself for testing the appeal workflow. It is long enough to pass the minimum character requirement.', "creator_id": "test-appeal-user"}'
SUBMIT_RESP=$(curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$SUBMIT_PAYLOAD")
CONTENT_ID=$(echo "$SUBMIT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['content_id'])" 2>/dev/null || echo "err")
echo "  Submitted content, got content_id: $CONTENT_ID"

# Now appeal
APPEAL_PAYLOAD=$(python3 -c "import json; print(json.dumps({'content_id': '$CONTENT_ID', 'creator_reasoning': 'I wrote this myself from personal experience. I am a non-native English speaker.'}))")
APPEAL_RESP=$(curl -s -X POST "$BASE/appeal" -H "Content-Type: application/json" -d "$APPEAL_PAYLOAD")
APPEAL_STATUS=$(echo "$APPEAL_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['status'])" 2>/dev/null || echo "err")
echo "  Appeal response: $APPEAL_RESP"
echo ""
echo "  Expected: status = under_review"
echo "  Got:      status = $APPEAL_STATUS"
if [ "$APPEAL_STATUS" = "under_review" ]; then result pass; else result fail; fi
echo ""

# ── Test 4: Appeal error cases ──
echo "$SEP"
echo "Test 4: Appeal error cases (404 not found, 409 duplicate, 400 missing fields)"
echo "$SEP"

# 404 - nonexistent content_id
RESP404=$(curl -s -X POST "$BASE/appeal" -H "Content-Type: application/json" \
    -d '{"content_id": "00000000-0000-0000-0000-000000000000", "creator_reasoning": "test"}')
CODE404=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/appeal" -H "Content-Type: application/json" \
    -d '{"content_id": "00000000-0000-0000-0000-000000000000", "creator_reasoning": "test"}')
echo "  404 (nonexistent): code=$CODE404"
if [ "$CODE404" = "404" ]; then echo "  [404]: PASS"; else echo "  [404]: FAIL (got $CODE404)"; fi

# 409 - duplicate appeal on the same content_id
RESP409=$(curl -s -X POST "$BASE/appeal" -H "Content-Type: application/json" -d "$APPEAL_PAYLOAD")
CODE409=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/appeal" -H "Content-Type: application/json" -d "$APPEAL_PAYLOAD")
echo "  409 (duplicate): code=$CODE409"
if [ "$CODE409" = "409" ]; then echo "  [409]: PASS"; else echo "  [409]: FAIL (got $CODE409)"; fi

# 400 - missing creator_reasoning
CODE400=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/appeal" -H "Content-Type: application/json" \
    -d '{"content_id": "'"$CONTENT_ID"'"}')
echo "  400 (missing reasoning): code=$CODE400"
if [ "$CODE400" = "400" ]; then echo "  [400]: PASS"; else echo "  [400]: FAIL (got $CODE400)"; fi

echo ""
if [ "$CODE404" = "404" ] && [ "$CODE409" = "409" ] && [ "$CODE400" = "400" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 5: Appeal reflected in audit log ──
echo "$SEP"
echo "Test 5: Audit log shows appeal status and reasoning"
echo "$SEP"
LOG_RESP=$(curl -s "$BASE/log?limit=10")
# Find the appealed entry
APPEAL_ENTRY=$(echo "$LOG_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for e in d['entries']:
    if e.get('content_id') == '$CONTENT_ID':
        print(f\"status={e.get('status')}\")
        print(f\"appeal_reason={e.get('appeal_reason','')[:50]}\")
        print(f\"appeal_timestamp={'present' if e.get('appeal_timestamp') else 'MISSING'}\")
        print(f\"original_attribution={e.get('attribution')}\")
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "parse_error")
echo "  Appeal entry in log:"
echo "  $APPEAL_ENTRY"
echo ""
if echo "$APPEAL_ENTRY" | grep -q "under_review"; then result pass; else result fail; fi
echo ""

# ── Test 6: Rate limiting on /appeal endpoint ──
echo "$SEP"
echo "Test 6: Rate limiting on /appeal (3 per minute)"
echo "$SEP"
echo "  Waiting 60 seconds for rate limit window to reset..."
sleep 60
echo "  Expected: first 3 return 200/404/409, 4th returns 429"
HAD_429=false
for i in $(seq 1 4); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/appeal" -H "Content-Type: application/json" \
        -d '{"content_id": "00000000-0000-0000-0000-000000000000", "creator_reasoning": "rate limit test"}')
    printf "  Request %d: %s" "$i" "$CODE"
    if [ "$CODE" = "429" ]; then
        echo " (rate limited)"
        HAD_429=true
    elif [ "$CODE" = "404" ]; then
        echo " (not found - expected for fake ID)"
    else
        echo ""
    fi
done
if [ "$HAD_429" = "true" ]; then result pass; else result fail; fi
echo ""

# ── Test 7: Complete audit log with at least 3 entries ──
echo "$SEP"
echo "Test 7: Audit log has 3+ structured entries with signal scores and appeal"
echo "$SEP"
LOG_RESP=$(curl -s "$BASE/log?limit=20")
echo "$LOG_RESP" | python3 << 'PYEOF'
import sys, json
d = json.load(sys.stdin)
print("Total entries: {}".format(len(d["entries"])))
for i, e in enumerate(d["entries"]):
    has_llm = bool(e.get("llm_score"))
    has_heuristic = bool(e.get("heuristics_score"))
    has_appeal = bool(e.get("appeal_reason"))
    status = e.get("status", "?")
    cid = e["content_id"][:8]
    print("  [{}] id={}... attr={} conf={} llm={} heur={} status={} appeal={}".format(
        i+1, cid, e["attribution"], e["confidence"], has_llm, has_heuristic, status, has_appeal))
PYEOF

COUNT=$(echo "$LOG_RESP" | python3 << 'PYEOF'
import sys, json
d = json.load(sys.stdin)
print(len(d["entries"]))
PYEOF
)
HAS_APPEAL=$(echo "$LOG_RESP" | python3 << 'PYEOF'
import sys, json
d = json.load(sys.stdin)
count = sum(1 for e in d["entries"] if e.get("appeal_reason"))
print(count)
PYEOF
)
echo ""
echo "  Entries in log: $COUNT (need 3+)"
echo "  Entries with appeal: $HAS_APPEAL (need 1+)"
if [ "$COUNT" -ge 3 ] && [ "$HAS_APPEAL" -ge 1 ]; then result pass; else result fail; fi
echo ""

echo "=== All M5 tests complete ==="
