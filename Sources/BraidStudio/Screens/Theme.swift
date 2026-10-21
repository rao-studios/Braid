//
//  Theme.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The few drawing helpers every screen uses: a titled panel that returns its content
//        rectangle, a dim message for an empty panel, rows of styled text, short hashes.
//

import BraidKit
import BraidTerminal
import Foundation

enum Theme {
    /// Draws a panel and returns its content rect (inset one cell on each side inside the border).
    @discardableResult
    static func panel(_ title: String, focused: Bool = false, footer: Text? = nil, _ frame: inout Frame, _ rect: Rect) -> Rect {
        var box = Box.panel(title, focused: focused, palette: frame.palette, glyphs: frame.glyphs)
        box.footer = footer
        return box.render(in: rect, on: &frame.canvas).inset(top: 0, left: 1, bottom: 0, right: 1)
    }

    static func empty(_ message: String, _ frame: inout Frame, _ rect: Rect) {
        guard !rect.isEmpty else { return }
        for (row, line) in Paragraph.wrap(message, width: max(1, rect.width - 2)).prefix(rect.height).enumerated() {
            frame.canvas.put(line, x: rect.minX + 1, y: rect.minY + row, style: frame.palette.dim, clip: rect)
        }
    }

    /// Rows of text, each truncated to the rect, from its top.
    static func rows(_ lines: [Text], _ frame: inout Frame, _ rect: Rect) {
        guard !rect.isEmpty else { return }
        for (row, line) in lines.prefix(rect.height).enumerated() {
            frame.canvas.put(line.truncated(to: rect.width), x: rect.minX, y: rect.minY + row, clip: rect)
        }
    }

    static func short(_ id: String?, _ n: Int = 12) -> String {
        guard let id, !id.isEmpty else { return "—" }
        return id.count > n ? String(id.prefix(n)) : id
    }

    static func f(_ x: Float, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }
    static func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
