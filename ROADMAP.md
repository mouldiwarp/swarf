# Roadmap

Open work and loose ends. Remove an item when it's done; add new ones as they come up.

## Two-sided machining

Two-sided (flip) machining is in: dowel holes, side A, a roll about X, then side B (`Flip.swift`). Loose ends:

- **Run a flip job on the WorkBee.** Check three things:
  - The dowel holes line up after the roll.
  - Side-B cavities land where the model has them.
  - Re-probing Z on the new top is enough.

  The tests prove the geometry, but not the clamping or the real-world registration.
- **Clamps on side B.** Side B never cuts the frame, but it doesn't know where the clamps are. Keep-outs drawn on side A
  apply to side B over their full depth (`protectBelowZ` is dropped). Consider separate side-B keep-outs.
- **Necks.** Necks are thick (often over 45 mm with the headstock), so the dowel depth limit bites. Consider dowels
  that go only partway through the stock, or a shorter spoilboard depth.
- **Facing on side B.** It isn't offered (the user doesn't want it), but a blank thicker than the part relies on
  side-B pocketing or roughing to bring the back down.

## Accuracy

- **Exact walls for the remaining operations.** Cutout outlines, every pass of flat-end-mill pockets and
  drill-hole centres are moved onto the true model geometry with `Footprint` (Silhouette.swift); pocket passes
  limited by keep-outs, silhouette holes or the side-B frame are straightened (`straightenGridRuns`). Everything else
  still follows grid contours. Walls can be a few tenths of a mm off, and curved passes wobble from segment to segment
  (jerky motion on the machine):
  - pockets cut with a ball or V-bit tool
  - roughing (3D clearing)
  - waterline
  - V-carve outlines

  Each needs a test like `OperationTests.pocketWallsAreExactAtEveryDepth`: wall distance exact at every depth,
  zero gouges.

## App

- **Check that the export file name is remembered.** Typing a name and the live rename were checked in the
  app. Saving the name with the project and reopening it were not.
- **Check `M3 P0` / `M5 P0` and rapids on the WorkBee.** Run an exported file on the machine and confirm two
  things:
  - The "M3: No P parameter and no active tool with spindle" error is gone. If the Duet's `config.g` puts the
    spindle under a number other than 0 (the `R` value on its `M950` line), the RRF profiles need that number.
  - Rapids (`G0 … F5000`) now run at rapid speed rather than the cutting feed.

## Website and docs

