# Roadmap

Open work and loose ends. Remove an item when it's done; add new ones as they come up.

## Accuracy

- **Exact walls for the remaining operations.** Cutout outlines, the wall pass of flat-end-mill pockets and
  drill-hole centres are moved onto the true model geometry with `Footprint` (Silhouette.swift). Everything else
  still follows grid contours and can be a few tenths of a mm off on walls:
  - pockets cut with a ball or V-bit tool
  - roughing (3D clearing)
  - waterline
  - V-carve outlines

  Each needs a test like `OperationTests.pocketWallsAreExactAtEveryDepth`: wall distance exact at every depth,
  zero gouges.

## App

- **Check the Export dialog's File name field in the running app.** The engine side is tested
  (`exportFileNameCanBeChosen`). Typing, the live file-list preview, saving the name with the project and
  reopening it were never clicked through.
- **Check `M3 P0` / `M5 P0` on the WorkBee.** Run an exported file on the machine and confirm the
  "M3: No P parameter and no active tool with spindle" error is gone. If the Duet's `config.g` puts the spindle
  under a number other than 0 (the `R` value on its `M950` line), the RRF profiles need that number.

## Website and docs

- **gm-guitars.net/tools/swarf** may still say the default work zero is front-left. It is now centre-left,
  top of stock (`WorkOrigin.swarfDefault`). It may also need to mention the Recalculate All button and the
  export file name.
