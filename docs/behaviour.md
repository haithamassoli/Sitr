# Cover behaviour with overlapping windows (M3-T09)

What the user sees when windows of apps with different rules overlap, measured with two copies of the selftest stimulus
(`Stimulus.app` = `com.goldentik.SitrStimulus`, `Stimulus2.app` = `com.goldentik.SitrStimulus2`; recipe in
`docs/m3/integration.md`) under `.build/debug/Sitr --selftest overlap`. Terms: *person cover* = the tracked body box plus
Body Padding, drawn after detection; *pre-cover* = Curtain tiles drawn on frame arrival before detection; *fail-closed cover*
= Solid over a Curtain window while capture is down.

## Decision: what clips, what does not

| Cover | Clipped to the window's visible region? | Why |
|---|---|---|
| Person cover (Blur and Curtain apps) | **No** | It covers the person's box wherever it is. PRD M3-T09 allows exactly this: "no cover appears on an Off window unless a hidden person's box from a monitored app extends under it". Clipping it would uncover the part of the person that shows around the Off window's edge and would make the box jump as windows move. |
| Curtain pre-cover | **Yes** — clipped to the Curtain window's rect minus every window stacked above it (`WindowTracker` z-order) | An Off window above a Curtain window is *excluded from capture*, so the frame shows the Curtain window's content where the Off window is on screen; that region is dirty whenever the Curtain window changes underneath. Unclipped, the pre-cover would land on the Off window — a cover on an Off window with no person involved, which the PRD forbids. |
| Fail-closed cover | **Yes** — same clip | Same reason; and a Blur window stacked above a Curtain window must stay uncovered (FR10: Blur apps fail open). |

The clip is `subtract(rect, holes:)` in `Sources/Sitr/Windows/WindowTracker.swift` (rect minus the rects of the windows
above it, per display), applied in `Pipeline.preCoverSpecs` and `failClosedSpecs`. Person covers pass through untouched.

## Attribution

Each detection is attributed to the topmost window under the centre of its box (`[WindowRect].topmost(at:on:)` on the
tracker snapshot the pipeline holds; nil over the desktop → Default Rule). `Policy` then resolves Blur vs Curtain from that
bundle id. Consequences:

- A person in a Blur window whose box centre lies under an overlapping Curtain window is attributed to the Curtain app.
  Both modes produce a person cover, so nothing is left uncovered; only the mode label differs.
- A person in a window of an Off app is never detected: the app is not in the frame at all.
- A person whose box centre lies under an **Off** window is attributed to the Off app and is not covered — measured, and
  written up under "Known leak" below.

## The matrix

Filled in from the `overlap_*` lines of `--selftest overlap` (see `docs/m3/integration.md` for the raw lines and the load).

| # | Stacking | What happens | Cover on the top window? |
|---|---|---|---|
| 1 | Blur window (person shown) **under** an Off window placed over the person's box centre | The Off window is excluded from capture, so the person is fully visible in the frame and is tracked — but the box centre lands on the Off window, so the detection is **attributed to the Off app** and gets no cover at all (`attributed_to=["…SitrStimulus2"]`, `person_covers=0`). | No cover anywhere — see the leak below. |
| 2 | Curtain window **over** a Blur window (person shown in the Blur window) | The Curtain window's pre-covers stay inside it (`precovers_outside_curtain_window=0`); the person in the Blur window keeps its person cover. | Only the Curtain window's own pre-covers, inside it. |
| 3 | Two Curtain apps side by side | Each window's pre-covers stay inside that window (16 on A, 18 on B, `precovers_outside_their_window=0`); one app's motion never pre-covers the neighbour. | n/a |
| 4 | Curtain window **under** an Off window (the Off window over part of the Curtain window's scrolling text) | The frame *is* dirty under the Off window (the Off window is not in the frame, so the Curtain window's content shows there) and those tiles are marked, but the pre-cover is clipped to the Curtain window's visible region: 34 pre-covers, **0 on the Off window**, and the Off window's marker was never covered in 19 sampled frames. | No. |

### Known leak: a person under an Off window is not covered (scenario 1)

Attribution uses the **centre** of the detection box. When an Off window sits over the middle of a person who is inside a
monitored window, the whole person resolves to the Off app and stays uncovered — including the head and legs that are still
visible around the Off window. The Off window itself is excluded from capture, so the person is not hidden by it in the frame;
only on screen is the middle obscured.

This is a real gap, not a PRD violation (the PRD only constrains what may appear *on* an Off window), and it needs a decision
outside this task: either attribute by the largest *visible* area per app (split the box against the window stack and take the
app owning most of it) or attribute a box to the monitored app whenever any visible part of it lies in one. Both live in
`Pipeline.run` step 2 plus a helper in `WindowTracker.swift`. Filed here rather than fixed because it changes what "the app a
person belongs to" means, which the Policy owner should settle.

## Known limits (`// ponytail:` in code)

- Window rects come from the 10 Hz tracker poll, so during a window drag the pre-cover geometry lags up to 100 ms behind the
  true position (the leading edge can show briefly). Person covers follow detection and are unaffected.
- A Blur window stacked *over* a Curtain window: dirty rects inside the overlap come from the Blur window's content, and the
  Curtain state machine still marks the Curtain window's tiles under them. The clip then removes exactly that region (the
  Blur window is above), so nothing is drawn: a Blur window on top of a Curtain window is never pre-covered, which is the
  Blur contract. The tiles stay marked until the next verified frame, at no visible cost.
- Transparent or oddly shaped windows are treated as their full bounds (WindowServer gives bounds only).
- Two-display layouts are covered by the unit tests (`WindowGeometry`), not by a live run (one-display machine).
