# Swarf

**Free, open-source, Mac-native CAM for hobby CNC.** Swarf takes an STL and turns it into G-code.
Its default output is tailored to the **Ooznest WorkBee Z1+ (Duet / RepRapFirmware)**, and it ships
post-processors for most popular hobby machines.

![Simulation](docs/screenshot-simulation.png)

## Features

**Model setup (3-axis: X / Y / Z)**
- Fast binary and ASCII STL import, with a mesh health check (watertight, open edges).
- Rotate in 90° steps about X, Y or Z, or freely about Z.
- **Pick the face that points up**, or **the face that lies on the bed**, by clicking it.
- **Auto lay-flat**: puts the largest flat face down.
- **Undercut highlighting** shows faces a 3-axis machine can't reach from the chosen side.
- Unit detection (inch models are scaled ×25.4) and manual scale.

**Stock and work zero**
- Stock is either model bounds plus margins or an explicit size.
- The model sits at the top, centre or bottom of the stock, with an optional XY offset.
- Pick the work zero on a 9-point grid, with Z on the stock top or the bed.
  The WorkBee default is front-left, top of stock.
- Material library (MDF, plywood, soft/hard wood, acrylic, HDPE, foam, aluminium).
  The material scales each tool's default feeds.

**Operations**
| Strategy | Use |
|---|---|
| Facing | Surface the stock top |
| Pocket / Cavity | 2.5D carving inside the model outline, with exact passes on every flat floor |
| 3D Roughing | Waterline offset clearing with ramp entries and stock-to-leave |
| 3D Finish – Parallel | Raster at any angle, optionally limited to shallow slopes |
| 3D Finish – Waterline | Constant-Z contours, optionally limited to steep walls |
| V-Carve | Engraves text and logos with a V-bit: sharp corners, depth follows stroke width, optional flat-bottom depth limit |
| Drill (Peck) | Finds round holes in the model that match the tool diameter and pecks them: full retract to clear chips or a short chip-break lift. Blind holes stop at their floor; through holes go below the stock. Expanded into plain G0/G1 moves, so it runs on any firmware |
| Cutout (profile) | Through-cut with ramping multi-pass, internal holes first, **holding tabs** |

- **Full Processing**: one click analyses the model and builds facing, roughing,
  steep/shallow finishing and a cutout with tabs, choosing tools from your library.
- **V-carving**: engrave either the *recesses in the model's top face* (e.g. a plaque STL with
  sunken lettering) or the *model's whole outline* (e.g. an STL of extruded text or a logo) into the
  stock. The V-bit follows the medial axis of each shape at depth = half-width ÷ tan(½ angle), so the
  cone's edge traces the outline exactly. Explicit branches run into every sharp corner. A depth limit
  gives flat-bottomed letters, and stepdown splits deep carves into passes. Keep-out and machine-only
  regions limit what gets engraved, and the simulator treats engraved areas as intentional, not gouges.
- **Tabs**: count per loop (automatically moved onto straight sections) or click to place them.
  Rectangular or ramped/triangular, with settable width and height.
- **Keep-out regions**: drag a box over any feature you don't want milled. The tool stays a full
  cutter radius away, or you can allow cutting down to a set height. "Machine only within"
  regions limit an operation to an area. Regions apply to every operation or only to the ones
  you choose.
- Climb or conventional milling, radial and axial stock-to-leave, custom floors, boundary modes.

**Tool library**
- Flat, ball, bull-nose, V-bit and drill tools, with defaults for RPM, feed, plunge, stepdown,
  stepover and ramp.
- Chip-load readout and feeds-and-speeds sanity warnings.
- Saved for every project in `~/Library/Application Support/Swarf/tools.json`.
- Import Fusion 360 tool libraries (`.json`), plus Swarf JSON import/export.
- Edit a tool in the library and open projects using it pick up the new geometry. Each operation
  keeps its own feeds and T number.

**Simulation and checks**
- GPU-rendered material-removal simulation with playback and scrubbing.
- **Gouge check**: overcuts show in red, leftover stock as a blue heat map.
- Keep-out violation check, machine-envelope check, and flute-length and feed limits.
- Run-time estimate that accounts for acceleration.

**Post-processors**

| Machine | Notes |
|---|---|
| **Ooznest WorkBee Z1+ (Duet / RRF)** (default) | `;` comments, `G4 S` dwell, arcs, one file per tool (zero XY on the corner and probe Z before each file) |
| Generic Duet / RepRapFirmware | Single file with an `M291` tool-change prompt |
| Generic GRBL 1.1 | |
| Carbide 3D Shapeoko / Nomad | `M6` for Carbide Motion and BitSetter |
| Sienci LongMill / AltMill | `M6` handled by gSender |
| Inventables X-Carve | |
| SainSmart Genmitsu | |
| Onefinity (Buildbotics) | |
| grblHAL / FluidNC | |
| MASSO G3 | |
| LinuxCNC | |
| Mach3 / Mach4 | |
| UCCNC | |
| Marlin (MPCNC / LowRider) | |

Arc fitting (G2/G3) shortens files and smooths motion. Export also produces a printable
**PDF setup sheet** with the stock, the zero point, a top-view render and the tool list.

## How it works

The engine (`CAMCore`) is pure Swift and uses no GPL code:

1. The oriented mesh is rasterised into a height field. Triangle edges are stamped as well, so thin
   walls and ridges are never missed.
2. For each operation, the height field is "inverse-offset" by the exact cutter profile
   (flat / ball / bull / V) on the GPU with a Metal compute kernel. This is a heightmap drop-cutter
   that gives the lowest safe tool-tip height everywhere. The 3D strategies apply a half-cell
   conservative filter, so contact points between grid nodes can't gouge.
3. Keep-outs and boundaries are applied by raising the height field *before* the cutter offset,
   so every strategy keeps the right clearance without special cases.
4. Offsets come from exact Euclidean distance transforms, and contours from multi-level marching
   squares, oriented so loops are climb-milled by default.
5. The simulator removes material from a stock height field with sub-cell-exact cutter stamping,
   then compares the result with the model.

A full dome job (rough, two finishes and a cutout with tabs) generates in about 3 seconds on Apple
silicon.

## Building

Requires macOS 15+ and Xcode 16+ (Swift 6).

```bash
swift test -c release            # engine tests
scripts/build-app.sh             # → build/Swarf.app
open build/Swarf.app
```

### Command line

```bash
.build/release/swarf-cli model.stl --machine workbee-z1plus-rrf --out ./gcode --simulate --png preview.png
.build/release/swarf-cli --list-machines
```

Options: `--material`, `--quality draft|normal|fine`, `--lay-flat`, `--rotate x:90`,
`--ops facing,pocket,roughing,parallelFinish,waterlineFinish,vcarve,drill,cutout`, `--keepout x0,y0,x1,y1`,
`--vcarve-source recesses|silhouette`, `--vcarve-depth <mm>`.

## Safety

CNC machines are dangerous. Always check the toolpaths in the simulator, air-cut new jobs with Z
zeroed above the stock, keep hands clear, and wear eye and hearing protection. Machine profiles
are best-effort: check the header, spindle and tool-change behaviour against your controller
before your first cut. Swarf is provided under the MIT license **without warranty**.

## Roadmap

- V-carve with a separate flat end mill for clearing wide areas
- Rest machining (remaining material from the previous tool)
- Flip / two-sided setups with dowel registration
- Editable custom post-processors in the UI
- G-code panel synced with the 3D view

## License

MIT. See [LICENSE](LICENSE). Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
