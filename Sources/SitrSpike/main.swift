// sitr-spike: M1 measurement rigs. One subcommand per rig, each in its own file.
// Run from a shell (never via `open`) so the process inherits the terminal's Screen Recording grant.
import Foundation

let usage = """
usage: sitr-spike <rig> [options]
  capture   M1-T01  SCStream loop: cadence, idle frames, dirtyRects
  overlay   M1-T02  overlay panel + feedback-loop check
  latency   M1-T04  capture / blur-path / curtain-path latency
  blur      M1-T07  CIGaussianBlur / CIPixellate cost + strength curve
  detect    M1-T03  Vision detection ms/frame at 1280 and 1920
  system    M1-T08  capture + detect + render system cost
Each rig prints its numbers to stdout and exits on its own; use --help per rig.
"""

let argv = Array(CommandLine.arguments.dropFirst())
let rest = Array(argv.dropFirst())
switch argv.first {
case "capture": runCapture(rest)
case "overlay": runOverlay(rest)
case "latency": runLatency(rest)
case "blur": runBlur(rest)
case "detect": runDetectCost(rest)
case "system": runSystem(rest)
default:
    print(usage)
    exit(2)
}
