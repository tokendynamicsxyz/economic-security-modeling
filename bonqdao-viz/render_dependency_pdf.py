#!/usr/bin/env python3

"""
Render Slither Dependency Graphs to a Multi-Page PDF
===================================================

Input:
    slither_dependency_graph.json OR .yaml

Output:
    dependency_graph_report.pdf
"""

import json
import yaml
import math
import networkx as nx
import matplotlib.pyplot as plt

from reportlab.lib.pagesizes import LETTER
from reportlab.pdfgen import canvas
from reportlab.lib.units import inch
from tempfile import NamedTemporaryFile
from pathlib import Path


INPUT_FILE = "slither_dependency_graph.json"
OUTPUT_PDF = "dependency_graph_report.pdf"


# ------------------------------------------------------------
# Utility
# ------------------------------------------------------------

def load_graph(path):
    if path.endswith(".json"):
        with open(path) as f:
            return json.load(f)
    if path.endswith(".yaml") or path.endswith(".yml"):
        with open(path) as f:
            return yaml.safe_load(f)
    raise ValueError("Unsupported file type")


def save_matplotlib_fig_to_temp():
    tmp = NamedTemporaryFile(delete=False, suffix=".png")
    plt.savefig(tmp.name, bbox_inches="tight")
    plt.close()
    return tmp.name


def draw_page(c, title, description, image_path):
    width, height = LETTER

    c.setFont("Helvetica-Bold", 14)
    c.drawString(1 * inch, height - 1 * inch, title)

    c.setFont("Helvetica", 10)
    text = c.beginText(1 * inch, height - 1.5 * inch)
    for line in description.split("\n"):
        text.textLine(line)
    c.drawText(text)

    c.drawImage(
        image_path,
        1 * inch,
        1 * inch,
        width=width - 2 * inch,
        height=height - 3.5 * inch,
        preserveAspectRatio=True,
    )

    c.showPage()


# ------------------------------------------------------------
# Graph builders
# ------------------------------------------------------------

def build_bipartite_graph(data):
    G = nx.DiGraph()

    for edge in data["edges"]:
        if edge["type"] in ("reads", "writes"):
            src, dst = edge["from"], edge["to"]
            if edge["type"] == "reads":
                G.add_edge(dst, src, type="reads")   # variable → function
            else:
                G.add_edge(src, dst, type="writes")  # function → variable

    return G


def build_function_influence_graph(data):
    writers = {}
    readers = {}

    for fn, meta in data["functions"].items():
        for v in meta["writes"]:
            writers.setdefault(v, set()).add(fn)
        for v in meta["reads"]:
            readers.setdefault(v, set()).add(fn)

    G = nx.DiGraph()

    for v in writers:
        if v in readers:
            for w in writers[v]:
                for r in readers[v]:
                    if w != r:
                        G.add_edge(w, r, via=v)

    return G


# ------------------------------------------------------------
# Rendering
# ------------------------------------------------------------

def render_bipartite(G):
    funcs = {n for n in G.nodes if "." in n and "reserve" not in n}
    vars_ = set(G.nodes) - funcs

    pos = {}
    for i, f in enumerate(sorted(funcs)):
        pos[f] = (i, 1)
    for i, v in enumerate(sorted(vars_)):
        pos[v] = (i, 0)

    plt.figure(figsize=(12, 8))

    nx.draw_networkx_nodes(G, pos, nodelist=funcs, node_color="#6baed6", node_size=800)
    nx.draw_networkx_nodes(G, pos, nodelist=vars_, node_color="#74c476", node_size=800)

    read_edges = [(u, v) for u, v, d in G.edges(data=True) if d["type"] == "reads"]
    write_edges = [(u, v) for u, v, d in G.edges(data=True) if d["type"] == "writes"]

    nx.draw_networkx_edges(G, pos, edgelist=read_edges, edge_color="gray", arrows=True)
    nx.draw_networkx_edges(G, pos, edgelist=write_edges, edge_color="red", arrows=True)

    nx.draw_networkx_labels(G, pos, font_size=7)

    plt.axis("off")


def render_function_graph(G, layout="spring"):
    plt.figure(figsize=(10, 8))

    if layout == "spring":
        pos = nx.spring_layout(G, seed=42)
    elif layout == "shell":
        pos = nx.shell_layout(G)
    else:
        pos = nx.circular_layout(G)

    nx.draw_networkx_nodes(G, pos, node_color="#9ecae1", node_size=1000)
    nx.draw_networkx_edges(G, pos, arrowstyle="->", arrowsize=12)
    nx.draw_networkx_labels(G, pos, font_size=8)

    plt.axis("off")


# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

def main():
    data = load_graph(INPUT_FILE)
    c = canvas.Canvas(OUTPUT_PDF, pagesize=LETTER)

    # Page 1: Bipartite
    B = build_bipartite_graph(data)
    render_bipartite(B)
    img = save_matplotlib_fig_to_temp()
    draw_page(
        c,
        "Bipartite Function–Variable Dependency Graph",
        "This is a directed bipartite graph.\n"
        "Top nodes represent functions; bottom nodes represent state variables.\n"
        "Edges from variables to functions indicate reads.\n"
        "Edges from functions to variables indicate writes.\n"
        "Disconnected nodes are removed.\n"
        "Layout: vertical bipartite. Colors encode node type and write edges.",
        img,
    )

    # Page 2: Function influence (spring)
    F = build_function_influence_graph(data)
    render_function_graph(F, layout="spring")
    img = save_matplotlib_fig_to_temp()
    draw_page(
        c,
        "Function Influence Graph (Spring Layout)",
        "Nodes represent functions.\n"
        "An edge exists if one function writes a variable that another function reads.\n"
        "This graph highlights indirect semantic influence via shared state.\n"
        "Layout: force-directed (spring).",
        img,
    )

    # Page 3: Function influence (shell)
    render_function_graph(F, layout="shell")
    img = save_matplotlib_fig_to_temp()
    draw_page(
        c,
        "Function Influence Graph (Shell Layout)",
        "Same influence graph as previous page.\n"
        "Different layout emphasizes layering and clustering.\n"
        "Useful for comparing structural stability across layouts.",
        img,
    )

    c.save()
    print(f"Wrote {OUTPUT_PDF}")


if __name__ == "__main__":
    main()

