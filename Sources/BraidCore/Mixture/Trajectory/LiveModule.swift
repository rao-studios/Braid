//
//  LiveModule.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The trajectory module inside a session: fed every step, it hands the gate the next
//        observation's evidence e_t per strand. It reads the same numbers the offline module
//        reads from a log.
//

import Foundation

/// The module in a session: fed every step, it hands the gate the next observation's e_t per strand.
public struct LiveModule: Sendable {
    public var settings: ModuleSettings
    public var commons: Int?
    private var series: [ThreadSeries] = []

    public init(strands: Int, commons: Int?, settings: ModuleSettings = ModuleSettings()) {
        self.settings = settings
        self.commons = commons
        series = (0..<strands).map { _ in ThreadSeries(hlm: [], hknn: [], lift: [], trace: [], commonsHLM: []) }
    }

    /// Records the step and returns each strand's e_t for the gate's next observation.
    public mutating func push(_ step: Step) -> [Double] {
        guard let threads = step.threads else { return series.map { _ in 0 } }
        while series.count < threads.count { series.append(ThreadSeries(hlm: [], hknn: [], lift: [], trace: [], commonsHLM: [])) }
        for t in threads.indices {
            series[t].hlm.append(threads[t].hlm.map(Double.init))
            series[t].hknn.append(Double(threads[t].hknn))
            series[t].trace.append(threads[t].trace?.trace ?? 0)
            if let c = commons, t != c, let own = threads[t].plm, let base = threads[c].plm {
                series[t].lift.append(log(Double(max(own, 1e-30))) - log(Double(max(base, 1e-30))))
            } else {
                series[t].lift.append(nil)
            }
            series[t].commonsHLM.append(commons.flatMap { threads[$0].hlm.map(Double.init) })
        }
        return evidence()
    }

    /// A strand's own context position (the question path's sentence before the stem): its series
    /// gains the record's entropies and trace, with no lift, since the commons does not read it.
    public mutating func pushContext(_ record: ThreadRecord, strand t: Int) {
        guard t >= 0 else { return }
        while series.count <= t { series.append(ThreadSeries(hlm: [], hknn: [], lift: [], trace: [], commonsHLM: [])) }
        series[t].hlm.append(record.hlm.map(Double.init))
        series[t].hknn.append(Double(record.hknn))
        series[t].trace.append(record.trace?.trace ?? 0)
        series[t].lift.append(nil)
        series[t].commonsHLM.append(nil)
    }

    /// The e_t strand t's next observation carries: the reading at its last position (0 before any).
    public func evidence(strand t: Int) -> Double {
        guard series.indices.contains(t), series[t].count > 0 else { return 0 }
        return TrajectoryModule.read(series[t], at: series[t].count - 1, settings: settings).evidence
    }

    /// Every strand's e_t now.
    public func evidence() -> [Double] { series.indices.map { evidence(strand: $0) } }

    public mutating func detach(at index: Int) { if series.indices.contains(index) { series.remove(at: index) } }
    public mutating func attach() { series.append(ThreadSeries(hlm: [], hknn: [], lift: [], trace: [], commonsHLM: [])) }
}
