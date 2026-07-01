def compute_combined_score(llm_score: float, heuristics_score: float) -> tuple[float, str]:
    combined = 0.6 * llm_score + 0.4 * heuristics_score
    combined = round(combined, 2)

    if combined < 0.4:
        attribution = "ai"
    elif combined > 0.6:
        attribution = "human"
    else:
        attribution = "uncertain"

    return combined, attribution
