# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Swarf is a Mac-native (macOS 15+, Swift 6, SwiftPM only, no Xcode project) CAM app that turns an STL into
G-code. Its default target is the Ooznest WorkBee Z1+ on Duet/RepRapFirmware. MIT licensed.

Open work and loose ends are listed in `ROADMAP.md`. Check it when starting work, and update it when an item
is done or a new one comes up.

## Commands

```bash
swift test -c release                                  # all engine tests (always use release: CAM tests are slow in debug)
swift test -c release --filter DrillTests              # one suite
swift test -c release --filter DrillTests/pecksMatchingHoles   # one test
scripts/build-app.sh [debug|release]                   # builds build/Swarf.app (needed for document types to register)
swift build -c release && .build/release/swarf-cli Tests/Fixtures/dome_relief.stl --out out --simulate
.build/release/swarf-cli model.stl --png preview.png [--png-no-paths]   # top view: gouges red, leftover blue
.build/release/swarf-cli ~/Desktop/Project.swarf --out out --simulate   # reproduce a user's project exactly
scripts/make-guide.sh                                  # docs/guide/user-guide.html -> docs/Swarf-User-Guide.pdf (headless Chrome)
```

CI (`.github/workflows/ci.yml`) runs release tests, builds the app bundle, and smoke-tests the CLI on
`dome_relief.stl` and `pocket_plate.stl` (with `--machine grbl`). There is no linter.

## Architecture

Three targets share one engine:

- **`Sources/CAMCore`**: UI-free engine. Release builds use `-Ounchecked`, so out-of-bounds bugs are not
  trapped there; tests in release won't catch them either.
- **`Sources/SwarfApp`**: SwiftUI + Metal app (Swift 5 language mode).
- **`Sources/swarf-cli`**: headless front end over the same engine; the easiest way to debug toolpaths.

### Engine pipeline (height-field CAM)

1. `Job` (Job.swift) is the whole Codable project description: orientation, stock, work origin, regions
   (keep-out / machine-only boxes), operations, quality, test-cut settings.
2. `PlacedModel` (Setup.swift) applies orientation and puts the mesh in **stock space**: X/Y from 0 at the
   stock's front-left corner, Z = 0 at the stock bottom, `stockTop` = stock height. Everything in the engine
   works in stock space. Only `PostProcessor` subtracts the work origin when writing G-code.
3. `CAMContext` (CAMContext.swift) rasterises the mesh into a `Grid2D` height field (`Heightmap.rasterizeTop`,
   which also stamps triangle edges) plus a silhouette distance field. The context is shared by all operations
   of a job. `Grid2D.none` (-1e9) means no surface; `Grid2D.forbid` (1e9) means the tool may never be there.
4. Per operation, `obstacleHeights(op)` folds floor, stock-to-leave, boundary mode and regions into the height
   field **before** `ToolDilation.dilate` (Dilation.swift, Metal GPU with CPU fallback) offsets it by the exact
   cutter shape. The result, `toolField(op)`, is the lowest safe tool-tip Z everywhere. It is cached by a
   string key, so **any new setting that affects the field must be added to that key**. 3D strategies
   (roughing / parallel / waterline) get an extra conservative half-cell max pass.
5. Strategies are `CAMContext` extensions: Operations.swift (facing, pocket+roughing via `clearing`, parallel,
   waterline, cutout with tabs), VCarve.swift, Drill.swift. They read the tool field, build contours (marching
   squares in Contours.swift, Euclidean distance transforms in Grid.swift), and emit `Move`s via `PathBuilder`.
   Grid contours are only accurate to about a cell, and on tall walls the error changes with depth. Wherever exact
   size matters, contour points are moved onto the true geometry with `Footprint` (Silhouette.swift). It gives
   the exact XY distance to the projected mesh, optionally only for material above a Z (`minZ`). It is used for
   cutout outlines, every pass of flat-end-mill pockets (the wall pass at the tool radius, inner passes at radius +
   k × stepover), and hole centres and diameters in Drill.swift. Without it, curves come out as thousands of tiny
   segments whose direction wobbles, and the machine brakes and accelerates at every one.
   `refine` caps each move at two cells and takes an `accept` check (keep-outs, boundary). Anything new that
   produces finished walls should use it too, or parts come out a few tenths undersize. `minZ` clips triangles
   at that height, so sloped and filleted walls give the true cross-section.
   Pass limits with no exact geometry (silhouette holes, keep-outs, the side-B frame) are yes/no masks whose
   contours are pure cell staircases. `straightenGridRuns` (Operations.swift) replaces those stretches, and the
   inner pocket passes, with chords; on the wall pass it may reach 0.75 cells past the mask, which is always spare
   margin. Measure motion smoothness on real output by counting turn-direction flips between consecutive G1 moves.
6. `CAMContext.generate(op)` is the single entry point: it validates settings, dispatches by
   `OperationKind`, rejects non-finite moves, and appends warnings (feeds, flute length, test-cut, below
   stock). `JobTemplates.fullProcessing` (Templates.swift) picks operations from model traits.
7. Two-sided jobs (Flip.swift): `Job.flip` turns them on and `Operation.side` (Optional) puts an operation on side B.
   Side B uses its own `CAMContext` (`makeSideB`/`sideB`), built from `PlacedModel.rolledAboutX()`: (x, y, z) →
   (x, W − y, T − z), so side-B toolpaths are in the machine's coordinates after the flip. `FrameProtection` keeps
   side B off the stock frame and side A's tabs. Side-A cutout settings therefore feed side B's cache key
   (`ProjectModel.cutoutsKey`). `.dowelHoles` drills pairs mirrored across the Y centre line: hand-placed `DowelSettings.picks` (validated by
   `dowelProblem`) or automatic (`dowelPositions`). `Toolpath.rolledAboutX` maps side B back
   for display and simulation, and `PostProcessor.process` writes one file set per `FlipStage`.
8. `StockSimulator` (Simulation.swift) removes material from a stock height field and compares it with the
   model (gouges / leftover). It also checks keep-out violations.
9. `PostProcessor` (Post.swift) writes the files. Machine dialects are data: a `MachineProfile` in
   `MachineProfile.builtIn`. The WorkBee profile splits output into one file per tool. `ArcFitter` turns
   linear moves into G2/G3. Names and comments are sanitised to ASCII so they can't inject G-code, and
   file names stay inside the chosen folder.

### App

- `SwarfDocument` (Document.swift) is a `ReferenceFileDocument` for `.swarf` **packages** holding `job.json`,
  `model.stl` and `name.txt`. STLs are always *imported* into a new project and are never documents, so
  autosave can never overwrite the user's STL.
- `ProjectModel` (ProjectModel.swift) owns regeneration: debounced `scheduleGeneration`, a `CAMContext`
  rebuilt only when `makeContextKey` changes (orientation, stock, regions, test cut, quality, safe height,
  margin), and per-operation toolpath caching keyed on the operation's JSON (`opKey`). If you add a
  `Job`-level field that affects geometry, add it to `makeContextKey`. `SimRunner` drives the animated
  simulation.
- `ToolLibraryStore` persists the tool library to `~/Library/Application Support/Swarf/tools.json`.
  Operations embed a copy of their `Tool`; open projects pick up library edits, but each operation keeps its
  own feeds.

## Rules (from CONTRIBUTING.md)

- The engine must stay MIT-compatible: no GPL dependencies.
- Every CAM change needs a test (Swift Testing, `Tests/CAMCoreTests`) that simulates the result and asserts
  **zero gouges**. Tests build geometry from `STL.box` / `STL.dome` / `STL.merge` or use `Tests/Fixtures`.
- New machine profile: add it to `MachineProfile.builtIn`, add a `PostTests` case checking header, spindle
  and tool-change output, and cite where the dialect was verified.
- `Job`, `Operation` and `Tool` must keep decoding old projects and `tools.json`. They use synthesized
  Codable (no custom `init(from:)`), which throws on a missing non-Optional key. So make new persisted
  fields Optional with a computed accessor, as `Job.testCut` / `testCutSettings` do, and add a back-compat
  decode test like `offByDefaultAndOldProjectsStillOpen`.
- Never write to a user's source STL.

## Running the app during development

The user often has `build/Swarf.app` open with unsaved work. Never `killall`/`pkill` Swarf. Launch your own
copy, track its PID, and kill only that PID. Take screenshots with `scripts/snap.sh <pid> <out.png>`, which
captures by PID rather than window title.
