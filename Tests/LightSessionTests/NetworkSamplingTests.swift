import XCTest
@testable import LightSession

/// The sampling decision.
///
/// Two properties carry this feature and neither is visible from one session: the share of
/// sessions kept has to match the rate asked for, and the weight has to be the reciprocal of that
/// share. Get either wrong and every count the server reports is off by the same factor —
/// silently, because the number still looks plausible.
final class NetworkSamplingTests: XCTestCase {

    private func sessions(_ count: Int) -> [String] {
        (0..<count).map { "session-\($0)" }
    }

    // MARK: - Off

    func testTheDefaultRecordsEverythingAndClaimsNothingExtra() {
        for session in sessions(50) {
            XCTAssertEqual(NetworkSampling.weight(sessionId: session, rate: 1.0, failed: false), 1)
            XCTAssertEqual(NetworkSampling.weight(sessionId: session, rate: 1.0, failed: true), 1)
        }
    }

    /// A rate above one, a NaN, an infinity — all caller mistakes. The safe reading of a mistake is
    /// to record everything: too much data costs money, too little is a wrong answer nobody can
    /// detect from the outside.
    func testARateThatIsNotARateRecordsEverything() {
        for rate in [1.5, 42.0, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(
                NetworkSampling.weight(sessionId: "s", rate: rate, failed: false), 1,
                "rate \(rate)"
            )
        }
    }

    // MARK: - The share kept

    /// The property the whole design rests on.
    func testTheShareOfSessionsKeptMatchesTheRateAskedFor() {
        let all = sessions(20_000)
        for rate in [0.5, 0.25, 0.1, 0.05, 0.01] {
            let kept = all.filter { NetworkSampling.inSample(sessionId: $0, rate: rate) }.count
            let share = Double(kept) / Double(all.count)
            // A 15% relative tolerance, and for the bucketing rather than for luck: this is a hash
            // over a fixed set of ids, so the share is determined, not converging.
            XCTAssertTrue(
                share > rate * 0.85 && share < rate * 1.15,
                "rate \(rate) kept \(String(format: "%.4f", share))"
            )
        }
    }

    /// The multiplication the server performs, run backwards. If the weight and the share
    /// disagree, the estimate is wrong.
    func testWeightTimesTheShareKeptReconstructsTheTraffic() {
        let all = sessions(20_000)
        for rate in [0.5, 0.25, 0.1, 0.05, 0.01] {
            let kept = all.filter { NetworkSampling.inSample(sessionId: $0, rate: rate) }
            let weight = NetworkSampling.weight(sessionId: kept[0], rate: rate, failed: false)!
            let estimated = Double(kept.count * weight)
            XCTAssertTrue(
                estimated > Double(all.count) * 0.85 && estimated < Double(all.count) * 1.15,
                "rate \(rate) estimated \(estimated) of \(all.count)"
            )
        }
    }

    func testTheWeightIsTheReciprocalOfTheRate() {
        let all = sessions(20_000)
        for (rate, expected) in [(0.1, 10), (0.25, 4), (0.5, 2), (0.01, 100)] {
            let kept = all.first { NetworkSampling.inSample(sessionId: $0, rate: rate) }!
            XCTAssertEqual(
                NetworkSampling.weight(sessionId: kept, rate: rate, failed: false), expected,
                "rate \(rate)"
            )
        }
    }

    // MARK: - Failures are kept

    /// The reason the weight can be zero at all.
    func testAFailureIsRecordedEvenInASessionThatWasNotSampled() {
        let out = sessions(20_000).first { !NetworkSampling.inSample(sessionId: $0, rate: 0.01) }!
        XCTAssertEqual(
            NetworkSampling.weight(sessionId: out, rate: 0.01, failed: true), 0,
            "a failure outside the sample is stored and counted nowhere"
        )
        XCTAssertNil(
            NetworkSampling.weight(sessionId: out, rate: 0.01, failed: false),
            "a success outside the sample is not stored at all"
        )
    }

    /// Inside the sample a failure is ordinary traffic. Weight 0 here would read as a zero failure
    /// rate for exactly the sessions we can see.
    func testAFailureInsideTheSampleIsWeightedLikeEverythingElse() {
        let inSample = sessions(20_000).first { NetworkSampling.inSample(sessionId: $0, rate: 0.1) }!
        XCTAssertEqual(NetworkSampling.weight(sessionId: inSample, rate: 0.1, failed: true), 10)
        XCTAssertEqual(NetworkSampling.weight(sessionId: inSample, rate: 0.1, failed: false), 10)
    }

    func testARateOfZeroKeepsFailuresAndNothingElse() {
        for rate in [0.0, -1.0, 1e-9] {
            XCTAssertEqual(
                NetworkSampling.weight(sessionId: "s", rate: rate, failed: true), 0, "rate \(rate)"
            )
            XCTAssertNil(
                NetworkSampling.weight(sessionId: "s", rate: rate, failed: false), "rate \(rate)"
            )
        }
    }

    // MARK: - Stability

    /// Every request in a session must get the same verdict. A decision that wobbled mid-session
    /// would record a fraction of it — arriving at per-request sampling by accident, which is the
    /// thing this design exists to avoid.
    func testTheDecisionIsStableForASession() {
        for session in sessions(200) {
            let first = NetworkSampling.inSample(sessionId: session, rate: 0.3)
            for _ in 0..<50 {
                XCTAssertEqual(NetworkSampling.inSample(sessionId: session, rate: 0.3), first)
            }
        }
    }

    /// The hash is written out rather than taken from `hashValue`, and on this platform that is not
    /// caution: Swift seeds string hashing per process, so `hashValue` would give a session one
    /// verdict on this launch and another on the next. The spool carries a session across launches,
    /// so the two would land in one session's data.
    ///
    /// Pinned to values rather than to itself, so changing the algorithm is a decision.
    func testTheDecisionIsPinnedToTheIdAndNotToTheProcess() {
        XCTAssertTrue(
            NetworkSampling.inSample(sessionId: "1e527025-c3ae-40c1-bf98-7d6a67e759a6", rate: 0.5)
        )
        XCTAssertFalse(
            NetworkSampling.inSample(sessionId: "2C99B1BF-A9AE-4D2E-B985-E7805A76B120", rate: 0.01)
        )
    }

    /// Ids one character apart must land independently, or a device's sequential session ids all
    /// fall on the same side and a whole install is in or out together.
    func testNeighbouringIdsDoNotShareAVerdict() {
        let verdicts = (0..<64).map {
            NetworkSampling.inSample(sessionId: "session-aaa\($0)", rate: 0.5)
        }
        let kept = verdicts.filter { $0 }.count
        XCTAssertTrue(kept > 8 && kept < 56, "\(kept) of 64 neighbouring ids kept")
    }

    /// A weight multiplies, so it can never be absurd — that is the one direction this field can
    /// invent traffic in.
    func testNoWeightIsEverAbsurd() {
        for rate in [0.9, 0.5, 0.1, 0.01, 0.001, 0.0001] {
            for session in sessions(5_000) {
                guard let weight = NetworkSampling.weight(
                    sessionId: session, rate: rate, failed: false
                ) else { continue }
                XCTAssertTrue(weight >= 1 && weight <= 10_000, "rate \(rate) gave \(weight)")
            }
        }
    }
}
