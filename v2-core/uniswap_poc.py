#!/usr/bin/env python3
"""
Slither Dependency Graph PoC
============================

Static analysis of Solidity contracts using Slither's Python API.

Features:
- Multi-file Solidity analysis (raw solc mode)
- Call graph extraction (Function -> Function)
- State variable read/write dependency tracking
- Boolean inclusion/exclusion filters
- JSON + YAML export suitable for graph construction

Run from a directory containing Solidity files, e.g.:

    python slither_dependency_graph.py

Requirements:
    pip install slither-analyzer pyyaml
"""

import glob
import json
import yaml
from collections import defaultdict, deque
from typing import Dict, Set

from slither.slither import Slither
from slither.core.declarations.function import Function

# ============================================================
# CONFIGURATION
# ============================================================

# Directory containing Solidity files
SOLIDITY_DIR = "contracts"

# Variable-name substrings to INCLUDE (case-insensitive)
INCLUDE_VARIABLE_SUBSTRINGS = (
    "price",
    "reserve",
    "token",
)

# Exclude functions whose names start with these prefixes
EXCLUDE_FUNCTION_PREFIXES = (
    "I",      # Interfaces
)

# Exclude functions that have no state reads AND no state writes
EXCLUDE_NO_EFFECT_FUNCTIONS = True

# Output files
OUTPUT_JSON = "slither_dependency_graph.json"
OUTPUT_YAML = "slither_dependency_graph.yaml"

# ============================================================
# FILTER FUNCTIONS
# ============================================================

def variable_name_allowed(name: str) -> bool:
    lname = name.lower()
    return any(substr in lname for substr in INCLUDE_VARIABLE_SUBSTRINGS)

def function_name_allowed(name: str) -> bool:
    return not name.startswith(EXCLUDE_FUNCTION_PREFIXES)

def function_semantically_relevant(reads: Set[str], writes: Set[str]) -> bool:
    if not EXCLUDE_NO_EFFECT_FUNCTIONS:
        return True
    return bool(reads or writes)

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

def function_id(f: Function) -> str:
    return f"{f.contract.name}.{f.name}"

def is_entrypoint(f: Function) -> bool:
    return f.visibility in ("public", "external") and not f.is_constructor

def build_call_graph(functions):
    """
    Build Function -> Function internal call graph.
    Filters out InternalCall / SolidityCall objects.
    """
    graph = defaultdict(set)

    for f in functions:
        for call in f.internal_calls:
            if hasattr(call, "function") and isinstance(call.function, Function):
                graph[f].add(call.function)

    return graph

def reachable_functions(start: Function, call_graph) -> Set[Function]:
    """
    Compute transitive closure of internal calls.
    """
    visited = {start}
    queue = deque([start])

    while queue:
        current = queue.popleft()
        for nxt in call_graph.get(current, []):
            if nxt not in visited:
                visited.add(nxt)
                queue.append(nxt)

    return visited

# ============================================================
# ANALYSIS
# ============================================================

def analyze_solidity_file(path: str) -> Dict[str, dict]:
    """
    Analyze a single Solidity file as a compilation root.
    """
    sl = Slither(path, compile_force_framework="solc")

    functions = []
    for contract in sl.contracts:
        functions.extend(contract.functions)

    call_graph = build_call_graph(functions)

    results = {}

    for f in functions:
        if not is_entrypoint(f):
            continue
        if not function_name_allowed(f.name):
            continue

        reachable = reachable_functions(f, call_graph)

        reads = set()
        writes = set()
        callees = set()

        for g in reachable:
            if g is not f:
                callees.add(function_id(g))

            for v in g.state_variables_read:
                if variable_name_allowed(v.name):
                    reads.add(f"{v.contract.name}.{v.name}")

            for v in g.state_variables_written:
                if variable_name_allowed(v.name):
                    writes.add(f"{v.contract.name}.{v.name}")

        if not function_semantically_relevant(reads, writes):
            continue

        fid = function_id(f)
        results[fid] = {
            "entrypoint": True,
            "reads": sorted(reads),
            "writes": sorted(writes),
            "calls": sorted(callees),
        }

    return results

# ============================================================
# DRIVER
# ============================================================

def main():
    all_functions = {}
    edges = []

    solidity_files = sorted(glob.glob(f"{SOLIDITY_DIR}/*.sol"))

    if not solidity_files:
        raise RuntimeError(f"No Solidity files found in '{SOLIDITY_DIR}/'")

    for sol in solidity_files:
        print(f"[+] Analyzing {sol}")
        try:
            per_file = analyze_solidity_file(sol)
            all_functions.update(per_file)
        except Exception as e:
            print(f"[WARN] Skipped {sol}: {e}")

    # Build explicit graph edges (function -> function)
    for fn, data in all_functions.items():
        for callee in data["calls"]:
            edges.append({
                "from": fn,
                "to": callee,
                "type": "call"
            })
        for v in data["reads"]:
            edges.append({
                "from": fn,
                "to": v,
                "type": "reads"
            })
        for v in data["writes"]:
            edges.append({
                "from": fn,
                "to": v,
                "type": "writes"
            })

    graph = {
        "nodes": {
            "functions": list(all_functions.keys()),
            "variables": sorted(
                {e["to"] for e in edges if e["type"] in ("reads", "writes")}
            ),
        },
        "functions": all_functions,
        "edges": edges,
        "meta": {
            "source": "slither",
            "analysis": "dependency-graph",
        }
    }

    with open(OUTPUT_JSON, "w") as f:
        json.dump(graph, f, indent=2)

    with open(OUTPUT_YAML, "w") as f:
        yaml.safe_dump(graph, f, sort_keys=False)

    print(f"\n[✓] Wrote {OUTPUT_JSON}")
    print(f"[✓] Wrote {OUTPUT_YAML}")
    print(f"[✓] Functions included: {len(all_functions)}")
    print(f"[✓] Edges generated: {len(edges)}")

# ============================================================
# ENTRY
# ============================================================

if __name__ == "__main__":
    main()

