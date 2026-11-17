import AppIconCore
import SwiftUI

/// The model leaderboard: the user's own picks first, with public scores and release dates beside them.
struct RankingView: View {
    let standings: [ModelStanding]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Model Ranking")
                .font(.title2.bold())

            Table(standings.enumerated().map { Row(offset: $0.offset, element: $0.element) }) {
                TableColumn("#") { row in
                    Text("\(row.offset + 1)").foregroundStyle(.secondary)
                }
                .width(24)
                TableColumn("Model") { row in
                    HStack(spacing: 6) {
                        Text(row.element.choice.model.name)
                        if row.element.choice.model.isOlder {
                            Text("Older")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
                .width(min: 180, ideal: 210)
                TableColumn("Provider") { row in
                    Text(row.element.choice.provider.shortName).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 110)
                TableColumn("Your picks") { row in
                    Text(Self.picks(row.element))
                        .foregroundStyle(row.element.contests == 0 ? .secondary : .primary)
                }
                .width(min: 100, ideal: 110)
                TableColumn("Public score") { row in
                    Text(row.element.choice.model.arenaScore.map(String.init) ?? "–")
                        .monospacedDigit()
                        .foregroundStyle(row.element.choice.model.arenaScore == nil ? .secondary : .primary)
                }
                .width(min: 90, ideal: 95)
                TableColumn("Released") { row in
                    Text(row.element.choice.model.released?.label ?? "–").foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 85)
                TableColumn("Licence") { row in
                    if let license = row.element.choice.model.license {
                        LicenceBadge(license: license)
                            .help("\(license.name). \(license.summary)")
                    }
                }
                .width(min: 200, ideal: 215)
            }
            .frame(minHeight: 330)

            VStack(alignment: .leading, spacing: 6) {
                Text("**Your picks** counts the comparisons in which you marked one of that model's icons as a favourite, or exported it, out of the comparisons it took part in; a dash means none yet. The order starts from the public score and shifts towards your picks as you make more of them.")
                Text("**Licence** summarises each model's own licence as read on \(ArenaSnapshot.date); hover for details. When a model runs at a hosting provider, that provider's terms apply too. This is not legal advice.")
                Text("**Public score** is the \(ArenaSnapshot.source) rating as of \(ArenaSnapshot.date). It judges general images, not icons, and is not updated automatically.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 1010)
    }

    private static func picks(_ standing: ModelStanding) -> String {
        standing.contests == 0 ? "–" : "Won \(standing.wins) of \(standing.contests)"
    }
}

/// One line of the table: a standing and its position.
private struct Row: Identifiable {
    let offset: Int
    let element: ModelStanding
    var id: String { element.id }
}
