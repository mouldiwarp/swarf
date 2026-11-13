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

## Rest machining

Rest machining is in (`Rest.swift`): a smaller tool cuts only what a larger one left. Loose ends:

- **Cut a rest pass on the WorkBee** with a real small bit, and measure its flute length and shank. The starter values
  for the 2 mm, 1 mm and 0.9 mm bits are typical, not measured.
- **Uncut stock and the shank.** The shank is kept off the model, but not off leftover material that this tool itself
  can't reach. That needs leftover deep beside a wall within a shank radius of where the bit cuts; it hasn't come up in
  tests.
- **Reference by operation, not tool.** A rest pass follows a tool and uses its own area and depth. Following the
  earlier operation's actual settings (or its simulated stock) would remove the need to keep them matched.

## Cutout trench

The wide trench is in (`cutout` in Operations.swift, `CutoutTrench` in Job.swift). Loose ends:

- **Cut one on the WorkBee** and see whether chips really clear better, and whether a deeper stepdown is then safe.
- **Trench only where it's deep: not possible.** To cut the outer pass at depth, the cutter needs the whole trench
  above it cleared, so the outer pass has to start at the top. Time savings have to come from elsewhere.
- **Faster second pass.** The pass next to the part only cuts half the cutter's width, so it could run at a higher feed.
- **Outer pass beyond the stock.** With a small stock margin the outer pass cuts air along the edge. It's harmless but
  wastes time; it could be clipped to the stock.

## App

- **Check that the export file name is remembered.** Typing a name and the live rename were checked in the
  app. Saving the name with the project and reopening it were not.
- **Check `M3 P0` / `M5 P0` and rapids on the WorkBee.** Run an exported file on the machine and confirm two
  things:
  - The "M3: No P parameter and no active tool with spindle" error is gone. If the Duet's `config.g` puts the
    spindle under a number other than 0 (the `R` value on its `M950` line), the RRF profiles need that number.
  - Rapids (`G0 … F5000`) now run at rapid speed rather than the cutting feed.

## Website and docs

