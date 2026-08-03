import XCTest
@testable import Wythin

final class LiveStateCopyTests: XCTestCase {

    func testEveryStateHasATitleAndAFeeling() {
        for key in LiveStateKey.allCases {
            XCTAssertFalse(LiveStateCopy.title(for: key, on: Date()).isEmpty, "\(key)")
            XCTAssertFalse(LiveStateCopy.feeling(for: key).isEmpty, "\(key)")
        }
    }

    func testTitleIsStableWithinADay() {
        let day = Date()
        let first = LiveStateCopy.title(for: .engaged_performing, on: day)
        for _ in 0..<20 {
            XCTAssertEqual(LiveStateCopy.title(for: .engaged_performing, on: day), first,
                           "a re-render must not reword the title")
        }
    }

    func testTitleVariesAcrossDays() {
        let titles = (0..<14).map { offset -> String in
            let day = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
            return LiveStateCopy.title(for: .engaged_performing, on: day)
        }
        XCTAssertGreaterThan(Set(titles).count, 1, "two weeks of the same word is canned")
    }

    func testCopyCarriesNoTechnicalTerms() {
        let banned = ["HRV", "RMSSD", "RSA", "SDNN", "DFA", "LF/HF", "vagal",
                      "coherence", "entropy", "deceleration", "z-score", "baseline"]
        for key in LiveStateKey.allCases {
            let text = LiveStateCopy.title(for: key, on: Date()) + " " + LiveStateCopy.feeling(for: key)
            for term in banned {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(term),
                               "\(key) leaks \(term)")
            }
        }
    }

    func testFeelingIsASinglePlainClause() {
        for key in LiveStateKey.allCases {
            let feeling = LiveStateCopy.feeling(for: key)
            XCTAssertFalse(feeling.contains("."), "\(key): the feeling is a clause, not a sentence")
            XCTAssertLessThan(feeling.count, 60, "\(key): too long for the collapsed line")
        }
    }
}
