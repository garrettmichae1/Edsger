#!/usr/bin/env python3
"""Fail on output regressions before reporting latency. Inputs contain synthetic test text."""
import json
import statistics
import sys
from pathlib import Path


def load(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    indexed = {row["case"]: row for row in rows}
    if len(indexed) != len(rows):
        raise ValueError(f"Duplicate case names in {path}")
    return indexed


def compare(baseline, cached):
    required = {"agent-first", "agent-review", "agent-repair", "agent-project-switch",
                "chat-first", "chat-unicode", "chat-truncated", "math-first", "math-next",
                "chat-after-math"}
    if not required <= baseline.keys() or not baseline.keys() <= cached.keys():
        raise ValueError("Incomplete benchmark corpus")
    for name, before in baseline.items():
        after = cached[name]
        if (before["output"], before["output_tokens"], before["input"]) != (
                after["output"], after["output_tokens"], after["input"]):
            raise ValueError(f"Output/token-count/input regression: {name}")
        for row in (before, after):
            if row["decoded"] + row["reused"] != row["input"]:
                raise ValueError(f"Prompt accounting failure: {name}")
            if not 0 <= row["cache_bytes"] <= 96 * 1024 * 1024:
                raise ValueError(f"Memory budget failure: {name}")
        if before["reused"] != 0:
            raise ValueError("Baseline unexpectedly reused state")
    for name in ("agent-review", "agent-repair", "math-next"):
        if cached[name]["reused"] <= 0:
            raise ValueError(f"Expected a cache hit: {name}")
    for name in ("agent-project-switch", "chat-after-math"):
        if cached[name]["reused"] != 0:
            raise ValueError(f"Expected mode/project invalidation: {name}")
    followups = sorted(name for name in baseline if name.startswith("chat-followup-"))
    if not followups:
        raise ValueError("Missing repeated chat measurements")
    reference = baseline[followups[0]]["output"]
    for name in ("recovered-after-cancellation", "memory-pressure-fallback"):
        row = cached[name]
        if row["output"] != reference or row["reused"] != 0:
            raise ValueError(f"Recovery failed: {name}")
    if cached["memory-pressure-fallback"]["cache_bytes"] != 0:
        raise ValueError("Memory-pressure fallback retained a checkpoint")

    summary = {"identical_cases": len(baseline), "chat_repetitions": len(followups), "chat": {}}
    for field in ("prompt_s", "first_token_s", "first_update_s", "generation_s", "total_s"):
        before = [baseline[name][field] for name in followups]
        after = [cached[name][field] for name in followups]
        summary["chat"][field] = {
            "baseline_median": statistics.median(before), "cached_median": statistics.median(after),
            "baseline_range": [min(before), max(before)], "cached_range": [min(after), max(after)],
            "median_reduction_percent": 100 * (1 - statistics.median(after) / statistics.median(before)),
        }
    summary["individual_completions"] = {
        name: {"before_prompt_s": baseline[name]["prompt_s"], "after_prompt_s": cached[name]["prompt_s"],
               "before_total_s": baseline[name]["total_s"], "after_total_s": cached[name]["total_s"],
               "reused_tokens": cached[name]["reused"]}
        for name in ("agent-review", "agent-repair", "math-next")
    }
    return summary


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: compare-cache-results.py BASELINE.jsonl CACHED.jsonl")
    print(json.dumps(compare(load(sys.argv[1]), load(sys.argv[2])), indent=2))
