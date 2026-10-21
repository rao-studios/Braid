//
//  Records.swift
//  Braid
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: The playground's app on the Ambient Intelligence Index, the structure it records, the
//        test data (an invented harbour log), and the test query.
//  PIN:  Every fact is invented, so an answer that names one came from the Thread, never from the
//        commons. Each entry is one paragraph (one partition), opens with a word of its own, names
//        its subject first and states its fact second, and shares no sentence template with
//        another entry (retrieval matches templates: lift L4 fails on it). Every entry has
//        tags, which keeps Thread's graph extraction off. About 750 tokens in all: more than one
//        training window of 128, and more than the 512 that `braid thread sync` always trains at.
//

import AII

/// The app: its name in the index. `join()` registers it on this Mac as a lane of its own.
enum PlaygroundApp: AIIAppDescriptor {
    static let app: AIIApp = "braidplayground"
    static let displayName = "Braid Playground"
}

/// What the app records. AII files each value as an aii-record/1 document,
/// `braidplayground/log/<recordID>`, in the group `braidplayground-harbour`, under the lane's
/// owner (`local-braidplayground`), with `text` as its partitions.
struct LogEntry: AIIRecordable {
    static let kind: AIIRecord.Kind = "log"
    static let group = AIIRecord.Group(id: "harbour", label: "Skerrow harbour log")

    var recordID: String
    var title: String
    /// Embedded and searched by AII; read and trained on by the Thread.
    var text: String
    var tags: [String]
}

let harbourLog: [LogEntry] = [
    LogEntry(recordID: "harlow-light", title: "Harlow Light",
             text: "Harlow Light stands at the end of the north mole in Skerrow. Its keeper is Ines Calloway, who has trimmed the lamp every night since the winter of 1987.",
             tags: ["lighthouse", "keeper"]),
    LogEntry(recordID: "quillan-ferry", title: "Ferries to Quillan",
             text: "Ferries for Quillan leave from the east slip twice a day. The first sails at 7:40 and the last at 16:15; on Sundays only the late boat runs.",
             tags: ["ferry"]),
    LogEntry(recordID: "harbourmaster", title: "The harbourmaster",
             text: "Odran Feck has served as harbourmaster for twenty-two years. He keeps the tide tables in a green ledger and signs every mooring permit in red ink.",
             tags: ["harbourmaster"]),
    LogEntry(recordID: "tide-bell", title: "Old Margery",
             text: "A brass bell called Old Margery hangs above the fish market. Rung three times, she warns that the spring tide will cover the lower quay.",
             tags: ["bell", "tide"]),
    LogEntry(recordID: "boatyard", title: "Tarrant's boatyard",
             text: "Tarrant's boatyard builds one clinker skiff each year. This year's boat, the Wren, is planked in larch and will be launched on the first of May.",
             tags: ["boatyard"]),
    LogEntry(recordID: "pilots", title: "The pilot cutter",
             text: "Pilots meet incoming ships off Gannet Rock in the cutter Sable. Her crew of four is led by Maren Ashby, the only pilot licensed for night work.",
             tags: ["pilots"]),
    LogEntry(recordID: "fish-auction", title: "The Thursday auction",
             text: "Every Thursday the market sells the week's catch of hake and ling. Bidding opens at six, and the auctioneer, Col Durrant, never takes a bid after seven.",
             tags: ["market"]),
    LogEntry(recordID: "storm-1953", title: "The storm of 1953",
             text: "During the great storm of 1953 the breakwater lost forty yards of stone. It was rebuilt the next summer with granite shipped from Penhallow quarry.",
             tags: ["storm"]),
    LogEntry(recordID: "lifeboat", title: "The lifeboat",
             text: "Volunteers crew the lifeboat Grace Ellery from the station beside the west slip. When a vessel is reported in distress, a maroon is fired from the station roof.",
             tags: ["lifeboat"]),
    LogEntry(recordID: "chandlery", title: "Wick and Sons",
             text: "Wick and Sons sell rope, tar and paraffin from a shed on Pier Lane. Hamish Wick opens it at dawn and shuts it once the evening ferry is in.",
             tags: ["chandlery"]),
    LogEntry(recordID: "mooring-fees", title: "Mooring fees",
             text: "Visiting yachts pay four shillings a night to lie alongside the inner wall. The fees are collected at dusk by the harbourmaster's son, Tobin.",
             tags: ["moorings"]),
    LogEntry(recordID: "seals", title: "The seal count",
             text: "Grey seals haul out on the Skerries each October. Children from the island school counted one hundred and twelve pups last autumn.",
             tags: ["seals"]),
    LogEntry(recordID: "fog-horn", title: "The fog horn",
             text: "Whenever fog rolls in, the horn on Gannet Rock sounds two long blasts every ninety seconds. Fishermen call it the Widow, for its mournful note.",
             tags: ["fog"]),
    LogEntry(recordID: "ice-house", title: "The ice house",
             text: "Behind the herring sheds stands a stone ice house built in 1868. Until refrigeration came, it held ice cut from Loch Brannan every February.",
             tags: ["ice house"]),
    LogEntry(recordID: "regatta", title: "The regatta",
             text: "The Skerrow regatta is sailed on the last Saturday of July. Its silver trophy, the Brennock Cup, was won last year by the yawl Petrel.",
             tags: ["regatta"]),
    LogEntry(recordID: "post-boat", title: "The post boat",
             text: "Mail reaches the island on the post boat Kittiwake. She calls at the west steps on Tuesdays and Fridays, weather permitting.",
             tags: ["mail"]),
    LogEntry(recordID: "net-loft", title: "The net loft",
             text: "Upstairs in the net loft, Bridie Moran mends drift nets by lamplight. She charges a penny a fathom and will not work on a Sunday.",
             tags: ["nets"]),
    LogEntry(recordID: "kelp", title: "Kelp",
             text: "Kelp is cut from the western reefs each spring. Dried on the shingle, it is sold by the cartload to a glassworks at Tarn Ford.",
             tags: ["kelp"]),
]

/// The test query: the lighthouse entry in its own words, up to the fact only the log holds.
enum TestQuery {
    static let prompt = "Harlow Light stands at the end of the north mole in Skerrow. Its keeper is"
    static let expected = "Ines Calloway"
    /// What AII's own search is asked, to show the records are in the index. AII's prose search
    /// reaches a lane's records through the entities a query names, and an entry's tags are its
    /// entities here (graph extraction is off), so the query is the lighthouse entry's tag. A
    /// question that names no entity (2026-10-17: "Who looks after the lighthouse?") finds nothing.
    static let recall = "lighthouse"
}
