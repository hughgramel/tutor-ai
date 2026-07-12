"""
Generate a clean, printed (typeset) math worksheet PDF for the InkTutor demo.

The student solves problems by hand with Apple Pencil on top of this PDF, so
the layout leaves generous blank space under each problem for handwritten work.

Uses matplotlib mathtext (no LaTeX install required) to render equations, and
places all text with fig.text() in figure coordinates for precise control over
vertical spacing on a US Letter page.

Usage:
    python3 tools/generate_assignment.py

Output:
    assets/assignment.pdf
"""

import os

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "..", "assets", "assignment.pdf")

PAGE_WIDTH_IN = 8.5
PAGE_HEIGHT_IN = 11.0

TITLE = "Algebra 1 — Solving Quadratic Equations"
INSTRUCTIONS = "Solve each equation by factoring. Show your work."

PROBLEMS = [
    r"$x^2 - 5x + 6 = 0$",
    r"$x^2 + 2x - 8 = 0$",
    r"$2x^2 - 7x + 3 = 0$",
    r"$x^2 - 9 = 0$",
    r"$x^2 + 4x + 4 = 0$",
]

LEFT_MARGIN = 0.10  # figure-coordinate x for left-aligned text


def build_worksheet():
    fig = plt.figure(figsize=(PAGE_WIDTH_IN, PAGE_HEIGHT_IN))
    ax = fig.add_axes([0, 0, 1, 1])
    ax.axis("off")

    # -- Header --------------------------------------------------------
    fig.text(0.5, 0.955, TITLE, ha="center", va="top", fontsize=20, fontweight="bold")

    fig.text(
        LEFT_MARGIN,
        0.905,
        "Name: " + "_" * 28 + "     Date: " + "_" * 14,
        ha="left",
        va="top",
        fontsize=12,
    )

    fig.text(
        LEFT_MARGIN,
        0.868,
        INSTRUCTIONS,
        ha="left",
        va="top",
        fontsize=12,
        style="italic",
    )

    # Rule under the header block
    ax.plot([LEFT_MARGIN, 1 - LEFT_MARGIN], [0.845, 0.845], color="0.6", linewidth=0.8)

    # -- Problems --------------------------------------------------------
    # Evenly space problems down the remaining page, leaving lots of blank
    # room under each one for handwritten work.
    top = 0.79
    bottom = 0.06
    n = len(PROBLEMS)
    slot_height = (top - bottom) / n

    for i, problem in enumerate(PROBLEMS):
        slot_top = top - i * slot_height
        fig.text(
            LEFT_MARGIN,
            slot_top,
            f"{i + 1}.",
            ha="left",
            va="top",
            fontsize=14,
            fontweight="bold",
        )
        fig.text(
            LEFT_MARGIN + 0.05,
            slot_top,
            problem,
            ha="left",
            va="top",
            fontsize=17,
        )
        # Faint divider between the blank work areas (skip after last problem)
        if i < n - 1:
            divider_y = slot_top - slot_height + 0.012
            ax.plot(
                [LEFT_MARGIN, 1 - LEFT_MARGIN],
                [divider_y, divider_y],
                color="0.85",
                linewidth=0.6,
                linestyle=(0, (1, 3)),
            )

    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)

    return fig


def main():
    fig = build_worksheet()
    out_path = os.path.abspath(OUTPUT_PATH)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    fig.savefig(out_path, format="pdf")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()
