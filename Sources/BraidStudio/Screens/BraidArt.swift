//
//  BraidArt.swift
//  BraidStudio
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The braid screen's colours: each Thread's strand colour, and a token's from the strand
//        that supplied it — gold where the commons did, the off-white line where no strand reached
//        0.6 of it, dim where no retrieved context predicted it.
//  PIN:  A function of the state alone, so a frame can be tested as text.
//

import BraidKit
import BraidTerminal
import Foundation

enum BraidArt {
    static let dominance: Float = 0.6

    static func strandColor(_ index: Int, _ palette: Palette) -> Color {
        palette.braid.isEmpty ? .default : palette.braid[index % palette.braid.count]
    }

    /// A generated token's style: its dominant strand's colour, the commons' gold, or "shared".
    static func tokenStyle(step: Step, uncited: Bool, commons: Int?, colour: (Int) -> Color, palette: Palette) -> Style {
        guard let records = step.threads, !records.isEmpty else { return palette.text }
        var style: Style
        if let dominant = step.dominant(threshold: dominance) {
            style = Style(foreground: dominant == commons ? palette.goldColor : colour(dominant), background: palette.base.background)
        } else {
            style = Style(foreground: palette.line, background: palette.base.background)
        }
        if uncited { style = style.dim() }
        return style
    }
}
