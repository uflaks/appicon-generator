import AppIconCore
import Foundation

/// One comparison: the models that each delivered candidates for the same prompt, and
/// which of them the user picked.
public struct Contest: Codable, Identifiable, Sendable, Equatable {
    /// The run the candidates share; see ``Candidate/runID``.
    public let id: UUID
    public let date: Date
    /// The ``ModelChoice/id`` of every model that delivered.
    public var models: [String]
    /// How many favourites each model currently has in this comparison.
    public var picks: [String: Int] = [:]

    /// A comparison only says something once the user has picked from it.
    var isDecided: Bool { !picks.isEmpty }
}

/// How a model has fared in the user's own comparisons.
public struct ModelStanding: Identifiable, Sendable, Equatable {
    public let choice: ModelChoice
    /// Decided comparisons the model took part in.
    public let contests: Int
    /// Of those, the ones where one of its candidates was picked.
    public let wins: Int

    public var id: String { choice.id }

    /// The win rate to expect before the user has compared anything, taken from the public
    /// score: about 0.9 for the top-rated models down to about 0.1 for the lowest. Unrated
    /// models sit in the middle, or in the lower half if they are marked as older.
    var expectation: Double {
        guard let arena = choice.model.arenaScore else { return choice.model.isOlder ? 0.25 : 0.5 }
        return min(0.95, max(0.05, Double(arena - 700) / 600))
    }

    /// The user's win rate, started off at ``expectation`` and worth three comparisons of
    /// evidence. So a model nobody has compared keeps its public standing, one result nudges
    /// it, and a long record of the user's own picks takes over.
    var score: Double { (Double(wins) + 3 * expectation) / (Double(contests) + 3) }

    /// Ranks every model by ``score``: the user's own picks, weighed against the public score
    /// while there are few of them. Ties go to current models, then to the newer release.
    static func ranking(of choices: [ModelChoice], from contests: [Contest]) -> [ModelStanding] {
        let decided = contests.filter(\.isDecided)
        let standings = choices.map { choice in
            let played = decided.filter { $0.models.contains(choice.id) }
            return ModelStanding(
                choice: choice, contests: played.count,
                wins: played.filter { $0.picks[choice.id, default: 0] > 0 }.count)
        }
        // Current models come before older ones; within each group rated models come before
        // unrated ones, so a missing public score never reads as the worst score.
        return standings.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.score != y.score { return x.score > y.score }
            if x.choice.model.isOlder != y.choice.model.isOlder { return !x.choice.model.isOlder }
            let (p, q) = (x.choice.model.arenaScore ?? Int.min, y.choice.model.arenaScore ?? Int.min)
            if p != q { return p > q }
            let (m, n) = (x.choice.model.released ?? ReleaseDate(0, 1), y.choice.model.released ?? ReleaseDate(0, 1))
            if m != n { return m > n }
            return a.offset < b.offset
        }.map(\.element)
    }
}
