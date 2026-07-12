import Foundation

/// Hardcoded demo problems for the stage run (Task 13). Standalone and
/// unwired — nothing in the app loads `demoProblems` yet; whichever task
/// wires problem selection into `CanvasScreen`/`TutorController` picks these
/// up later. `spoken` is a plain-English reading for anyone narrating setup,
/// not something the model ever sees verbatim.
struct Problem {
    let id: String
    let latex: String
    let spoken: String
}

/// Three factoring quadratics, increasing difficulty, each with one classic
/// sign-error trap a middle-school student actually makes:
let demoProblems: [Problem] = [
    // 1. Easy — both roots negative, both factor signs positive (b > 0, c > 0).
    //    Trap: student sees "+6" and reaches for a negative constant term,
    //    writing (x-2)(x-3) instead of (x+2)(x+3).
    Problem(
        id: "quad-1",
        latex: "x^2+5x+6=0",
        spoken: "x squared plus five x plus six equals zero"
    ),

    // 2. Medium — c < 0, so factor signs must differ (one +, one -).
    //    Trap: student picks the right magnitudes (4 and 3) but assigns the
    //    minus sign to the wrong factor, writing (x+4)(x-3) instead of
    //    (x-4)(x+3) — check which root actually satisfies -x term.
    Problem(
        id: "quad-2",
        latex: "x^2-x-12=0",
        spoken: "x squared minus x minus twelve equals zero"
    ),

    // 3. Hard — leading coefficient != 1, needs the grouping/split method.
    //    Trap: when splitting 7x into 6x + x for grouping
    //    (2x^2+6x+x+3), a sign error on the second pair flips the answer,
    //    e.g. factoring out "-1" instead of "+1" and landing on
    //    (2x+1)(x-3) instead of the correct (2x+1)(x+3).
    Problem(
        id: "quad-3",
        latex: "2x^2+7x+3=0",
        spoken: "two x squared plus seven x plus three equals zero"
    ),
]
