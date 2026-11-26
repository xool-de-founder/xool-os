import CoreGraphics
import Foundation
// scripts/click.swift X Y : a left click at screen point X,Y (needs Accessibility for the terminal)
let a = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let p = CGPoint(x: a[0], y: a[1])
for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.post(tap: .cghidEventTap)
    usleep(60_000)
}
