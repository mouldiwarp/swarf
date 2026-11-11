# Contributing to Swarf

Thanks for helping make free CAM better on the Mac!

## Getting started

```bash
git clone https://github.com/mouldiwarp/swarf.git   # or your fork
cd swarf
swift test -c release        # engine tests (release mode keeps CAM tests fast)
scripts/build-app.sh debug   # builds build/Swarf.app
open build/Swarf.app
```

You can also open `Package.swift` in Xcode and run the `Swarf` scheme. Note that document types only
register when the app runs from the bundle produced by `scripts/build-app.sh`.

## Layout

| Path | What lives there |
|---|---|
| `Sources/CAMCore` | The UI-free engine: STL I/O, orientation, height-field CAM, post-processors, simulation |
| `Sources/SwarfApp` | The SwiftUI + Metal macOS app |
| `Sources/swarf-cli` | Headless command-line front end (great for debugging toolpaths) |
| `Tests/CAMCoreTests` | Swift Testing suites |
| `Tests/Fixtures` | Small STL models used by tests and CI |

## Debugging toolpaths

`swarf-cli model.stl --png preview.png --png-no-paths` renders the simulated stock with gouges in red
and leftover material in blue. Drop `--png-no-paths` to overlay the toolpaths.

## Adding a machine / post-processor

Machine dialects are data. Add a `MachineProfile` in `Sources/CAMCore/Post.swift`, include it in
`MachineProfile.builtIn`, and add a test in `PostTests` that checks the header, spindle and tool-change
output. Please name the controller firmware and cite where you verified the dialect.

## Ground rules

* The engine must stay MIT-compatible: no GPL dependencies.
* Every CAM change needs a test that simulates the result and asserts **zero gouges**.
* Never write to a user's source STL. Projects are separate `.swarf` packages.
