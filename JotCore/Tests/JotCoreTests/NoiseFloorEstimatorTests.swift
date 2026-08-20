import XCTest
@testable import JotCore

final class NoiseFloorEstimatorTests: XCTestCase {

    /// Below the minimum the percentile is noise about noise. Callers treat a nil
    /// floor as "no evidence", which everywhere in the pipeline means keep the audio.
    func testFloorIsNilUntilEnoughSamples() {
        var estimator = NoiseFloorEstimator()
        for _ in 0..<(NoiseFloorEstimator.minimumSamples - 1) {
            estimator.ingest(level: 0.2)
            XCTAssertNil(estimator.floorDB)
        }
        estimator.ingest(level: 0.2)
        XCTAssertNotNil(estimator.floorDB)
    }

    /// The reason it is a rolling low percentile and not "the first N ms":
    /// prewarm means audio starts at key-down, so a fast talker is ALREADY
    /// speaking in the head of the recording. Treating that as the floor would
    /// classify speech as the room and make every downstream decision worse.
    func testFloorConvergesWhenSpeechStartsAtSampleZero() {
        var estimator = NoiseFloorEstimator()
        // Loud from the very first sample, with the natural gaps between words.
        let quietRoom: Float = 0.02
        for index in 0..<40 {
            estimator.ingest(level: index % 4 == 3 ? quietRoom : 0.7)
        }
        let floor = try! XCTUnwrap(estimator.floorDB)
        XCTAssertEqual(floor, AudioLevelCurve.dBFS(fromLevel: quietRoom), accuracy: 0.5,
                       "the gaps between words are the room, even when speech starts immediately")
        XCTAssertGreaterThan(try! XCTUnwrap(estimator.measuredSNR), 30)
    }

    /// A loud room is the case the whole feature exists for: speech barely rises
    /// above it, and the measured separation says so.
    func testLoudRoomProducesLowSeparation() {
        var estimator = NoiseFloorEstimator()
        for _ in 0..<20 { estimator.ingest(level: 0.4) }
        estimator.ingest(level: 0.5)
        let snr = try! XCTUnwrap(estimator.measuredSNR)
        XCTAssertLessThan(snr, 8, "nothing rose meaningfully above this room")
    }

    /// One anomalous quiet buffer must not define the room — that is the whole
    /// point of a percentile rather than a minimum.
    func testSingleOutlierDoesNotSetTheFloor() {
        var estimator = NoiseFloorEstimator()
        estimator.ingest(level: 0.0) // one dropout
        for _ in 0..<30 { estimator.ingest(level: 0.3) }
        let floor = try! XCTUnwrap(estimator.floorDB)
        XCTAssertEqual(floor, AudioLevelCurve.dBFS(fromLevel: 0.3), accuracy: 0.5)
    }

    func testPeakTracksTheLoudestSample() {
        var estimator = NoiseFloorEstimator()
        for level in [Float(0.1), 0.9, 0.3] { estimator.ingest(level: level) }
        XCTAssertEqual(estimator.peakDB, AudioLevelCurve.dBFS(fromLevel: 0.9), accuracy: 0.001)
    }

    /// A floor from nine minutes ago is not this room any more.
    func testWindowIsBounded() {
        var estimator = NoiseFloorEstimator(capacity: 16)
        for _ in 0..<16 { estimator.ingest(level: 0.01) } // old, quiet room
        for _ in 0..<16 { estimator.ingest(level: 0.4) }  // someone turned on a fan
        let floor = try! XCTUnwrap(estimator.floorDB)
        XCTAssertEqual(floor, AudioLevelCurve.dBFS(fromLevel: 0.4), accuracy: 0.5)
    }
}
