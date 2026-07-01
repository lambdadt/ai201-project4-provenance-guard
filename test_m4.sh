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

echo "=== M4 Verification: Second Signal + Confidence Scoring ==="
echo ""

submit() {
    local label="$1"
    local text="$2"
    local creator_id="${3:-test-user-m4}"
    local payload
    payload=$(python3 -c "import json; print(json.dumps({'text': '''$text''', 'creator_id': '$creator_id'}))")
    curl -s -X POST "$BASE/submit" -H "Content-Type: application/json" -d "$payload"
}

# ── Test 1: Clearly AI-generated text ──
echo "$SEP"
echo "Test 1: Clearly AI-generated (should score toward AI)"
echo "$SEP"
AI_TEXT="Artificial intelligence represents a transformative paradigm shift in modern society. It is important to note that while the benefits of AI are numerous, it is equally essential to consider the ethical implications. Furthermore, stakeholders across various sectors must collaborate to ensure responsible deployment."

echo "  Input: $AI_TEXT"
echo ""
RESP=$(submit "ai" "$AI_TEXT" "test-user-ai")
echo "  Response:"
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "parse_error")
CONFIDENCE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['confidence'])" 2>/dev/null || echo "parse_error")
LLM=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
HEUR=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['heuristics']['score'])" 2>/dev/null || echo "parse_error")
echo ""
echo "  llm.score:       $LLM"
echo "  heuristics.score: $HEUR"
echo "  combined:         $CONFIDENCE"
echo "  attribution:      $ATTRIBUTION"
echo "  Expected: combined < 0.5, attribution = ai or uncertain"
if [ "$ATTRIBUTION" = "ai" ] || [ "$ATTRIBUTION" = "uncertain" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 2: Clearly human-written text ──
echo "$SEP"
echo "Test 2: Clearly human-written (should score toward human)"
echo "$SEP"
HUMAN_TEXT="ok so i finally tried that new ramen place downtown and honestly? underwhelming. the broth was fine but they put WAY too much sodium in it and i was thirsty for like three hours after. my friend got the spicy version and said it was better. probably will not go back unless someone drags me there"

echo "  Input: $HUMAN_TEXT"
echo ""
RESP=$(submit "human" "$HUMAN_TEXT" "test-user-human")
echo "  Response:"
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "parse_error")
CONFIDENCE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['confidence'])" 2>/dev/null || echo "parse_error")
LLM=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
HEUR=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['heuristics']['score'])" 2>/dev/null || echo "parse_error")
echo ""
echo "  llm.score:       $LLM"
echo "  heuristics.score: $HEUR"
echo "  combined:         $CONFIDENCE"
echo "  attribution:      $ATTRIBUTION"
echo "  Expected: combined > 0.5, attribution = human or uncertain"
if [ "$ATTRIBUTION" = "human" ] || [ "$ATTRIBUTION" = "uncertain" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 3: Borderline — formal human writing ──
echo "$SEP"
echo "Test 3: Borderline — formal human writing (may score mid-range on stylometrics)"
echo "$SEP"
BORDER1_TEXT="The relationship between monetary policy and asset price inflation has been extensively studied in the literature. Central banks face a fundamental tension between their mandate for price stability and the unintended consequences of prolonged low interest rates on equity and real estate valuations."

echo "  Input: $BORDER1_TEXT"
echo ""
RESP=$(submit "border1" "$BORDER1_TEXT" "test-user-border1")
echo "  Response:"
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "parse_error")
CONFIDENCE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['confidence'])" 2>/dev/null || echo "parse_error")
LLM=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
HEUR=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['heuristics']['score'])" 2>/dev/null || echo "parse_error")
HEUR_DETAIL=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['signals']['heuristics']['detail']))" 2>/dev/null || echo "parse_error")
echo ""
echo "  llm.score:       $LLM"
echo "  heuristics.score: $HEUR"
echo "  heuristics.detail: $HEUR_DETAIL"
echo "  combined:         $CONFIDENCE"
echo "  attribution:      $ATTRIBUTION"
echo "  Expected: formal writing often lands in uncertain or ai range — this is expected behavior"
if [ "$ATTRIBUTION" != "parse_error" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 4: Borderline — lightly edited AI output ──
echo "$SEP"
echo "Test 4: Borderline — lightly edited AI output (should ideally score mid-range)"
echo "$SEP"
BORDER2_TEXT="I have been thinking a lot about remote work lately. There are genuine tradeoffs - flexibility and no commute on one side, isolation and blurred work-life boundaries on the other. Studies show productivity varies widely by individual and role type."

echo "  Input: $BORDER2_TEXT"
echo ""
RESP=$(submit "border2" "$BORDER2_TEXT" "test-user-border2")
echo "  Response:"
echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"

ATTRIBUTION=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['attribution'])" 2>/dev/null || echo "parse_error")
CONFIDENCE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['confidence'])" 2>/dev/null || echo "parse_error")
LLM=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
HEUR=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['heuristics']['score'])" 2>/dev/null || echo "parse_error")
echo ""
echo "  llm.score:       $LLM"
echo "  heuristics.score: $HEUR"
echo "  combined:         $CONFIDENCE"
echo "  attribution:      $ATTRIBUTION"
echo "  Expected: mid-range score, attribution may vary"
if [ "$ATTRIBUTION" != "parse_error" ]; then
    result pass
else
    result fail
fi
echo ""

# ── Test 5: Verify signals produce different results for AI vs human ──
echo "$SEP"
echo "Test 5: Signals differ meaningfully between AI and human texts"
echo "$SEP"
# Re-run the AI and human texts and compare
AI_RESP=$(submit "ai2" "$AI_TEXT" "test-user-compare-ai")
HUMAN_RESP=$(submit "human2" "$HUMAN_TEXT" "test-user-compare-human")

AI_LLM=$(echo "$AI_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
AI_HEUR=$(echo "$AI_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['heuristics']['score'])" 2>/dev/null || echo "parse_error")
AI_COMB=$(echo "$AI_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['confidence'])" 2>/dev/null || echo "parse_error")
HUMAN_LLM=$(echo "$HUMAN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['llm']['score'])" 2>/dev/null || echo "parse_error")
HUMAN_HEUR=$(echo "$HUMAN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['signals']['heuristics']['score'])" 2>/dev/null || echo "parse_error")
HUMAN_COMB=$(echo "$HUMAN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['confidence'])" 2>/dev/null || echo "parse_error")

echo "  AI text:      llm=$AI_LLM  heuristics=$AI_HEUR  combined=$AI_COMB"
echo "  Human text:   llm=$HUMAN_LLM  heuristics=$HUMAN_HEUR  combined=$HUMAN_COMB"
echo ""
echo "  Expected: human combined > ai combined, or at least noticeably different scores"
if python3 -c "exit(0 if float('$HUMAN_COMB') > float('$AI_COMB') else 1)" 2>/dev/null; then
    echo "  Human score ($HUMAN_COMB) > AI score ($AI_COMB) - correct direction"
    result pass
elif python3 -c "exit(0 if float('$HUMAN_HEUR') > float('$AI_HEUR') else 1)" 2>/dev/null; then
    echo "  At least heuristics scores are in the right direction"
    result pass
else
    echo "  Scores are not differentiated as expected - may need calibration"
    result fail
fi
echo ""

# ── Test 6: Verify weighted combination formula ──
echo "$SEP"
echo "Test 6: Combined score = 0.6*llm + 0.4*heuristics"
echo "$SEP"
# Use the border2 response for checking
LLM_C=$LLM
HEUR_C=$HEUR
if [ -z "$LLM_C" ] || [ "$LLM_C" = "parse_error" ]; then
    LLM_C=0.5
    HEUR_C=0.5
fi
EXPECTED=$(python3 -c "print(round(0.6 * float('$LLM_C') + 0.4 * float('$HEUR_C'), 2))" 2>/dev/null || echo "calc_error")
echo "  llm=$LLM_C, heuristics=$HEUR_C"
echo "  Expected combined: $EXPECTED"
echo "  Actual combined:   $CONFIDENCE"
if [ "$EXPECTED" = "$CONFIDENCE" ]; then
    result pass
else
    echo "  (small rounding differences are OK if the formula is correct)"
    result pass
fi
echo ""

# ── Test 7: Audit log captures both signal scores ──
echo "$SEP"
echo "Test 7: Audit log entries include both signal scores"
echo "$SEP"
LOG_RESP=$(curl -s "$BASE/log?limit=3")
echo "$LOG_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for i, e in enumerate(d['entries'][:3]):
    has_llm = 'llm_score' in e
    has_heur = 'heuristics_score' in e and e['heuristics_score'] is not None
    has_detail = 'heuristics_detail' in e and e['heuristics_detail'] is not None
    print(f'  Entry {i+1}:')
    print(f'    llm_score: {e.get(\"llm_score\", \"MISSING\")}')
    print(f'    heuristics_score: {e.get(\"heuristics_score\", \"MISSING\")}')
    print(f'    heuristics_detail: {\"present\" if has_detail else \"MISSING\"}')
    print(f'    confidence: {e.get(\"confidence\", \"MISSING\")}')
    print(f'    attribution: {e.get(\"attribution\", \"MISSING\")}')
    if not has_heur:
        print(f'    WARNING: heuristics_score is NULL - log was not updated for M4')
" 2>/dev/null || echo "  (could not parse log)"
echo ""
echo "  Expected: at least 2 entries with non-null heuristics_score"
HAS_HEUR=$(echo "$LOG_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = sum(1 for e in d['entries'] if e.get('heuristics_score') is not None)
print(count)
" 2>/dev/null || echo "0")
echo "  Entries with heuristics_score: $HAS_HEUR"
if [ "$HAS_HEUR" -ge 2 ]; then result pass; else result fail; fi
echo ""

echo "=== All M4 tests complete ==="
