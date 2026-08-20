import XCTest
@testable import JotCore

/// The arithmetic that decides whether a recording is kept or destroyed.
/// `AudioCaptureEngine` had no tests at all; this is the part of it that most
/// deserved them, which is why the curve was extracted into a pure type.
final class AudioLevelCurveTests: XCTestCase {

    /// The two thresholds the whole pipeline turns on, stated in dB so it is
    /// obvious how little headroom they leave: −58 dBFS is quieter than an
    /// occupied room, which is exactly why noise breaks the energy gates.
    func testShippingThresholdsInDecibels() {
        XCTAssertEqual(AudioLevelCurve.dBFS(fromLevel: 0.06), -58.4, accuracy: 0.1)
        XCTAssertEqual(AudioLevelCurve.dBFS(fromLevel: 0.08), -54.6, accuracy: 0.1)
    }

    /// Above this the curve stops distinguishing louder from loudest, so any SNR
    /// built on it understates itself. Documented as a lower bound, asserted here.
    func testCurveSaturatesAtMinus21dB() {
        XCTAssertEqual(AudioLevelCurve.dBFS(fromLevel: 1.0), -20.8, accuracy: 0.1)
        XCTAssertEqual(AudioLevelCurve.saturationDBFS, -20.8, accuracy: 0.1)
        // Everything at or above saturation reports the same dB — by design.
        XCTAssertEqual(
            AudioLevelCurve.dBFS(fromLevel: 1.0),
            AudioLevelCurve.dBFS(fromLevel: 2.0),
            accuracy: 0.0001
        )
    }

    func testLevelAndRMSRoundTrip() {
        for level in [Float(0.01), 0.06, 0.08, 0.25, 0.5, 0.99] {
            let back = AudioLevelCurve.level(fromRMS: AudioLevelCurve.rms(fromLevel: level))
            XCTAssertEqual(back, level, accuracy: 0.0005, "round trip failed at \(level)")
        }
    }

    /// Digital silence must be a finite number, not −∞: the estimator averages
    /// these and one infinity would poison the floor for the whole session.
    func testSilenceIsFiniteAndFloored() {
        XCTAssertEqual(AudioLevelCurve.level(fromRMS: 0), 0)
        XCTAssertEqual(AudioLevelCurve.dBFS(fromLevel: 0), AudioLevelCurve.floorDBFS)
        XCTAssertTrue(AudioLevelCurve.dBFS(fromLevel: 0).isFinite)
    }

    func testLevelIsMonotonicInRMS() {
        var previous: Float = -1
        for step in 0...100 {
            let level = AudioLevelCurve.level(fromRMS: Float(step) / 400)
            XCTAssertGreaterThanOrEqual(level, previous)
            previous = level
        }
    }
}
