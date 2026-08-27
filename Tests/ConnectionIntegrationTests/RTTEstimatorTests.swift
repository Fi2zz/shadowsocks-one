import Foundation
import XCTest
@testable import ShadowsocksBrowserPacketTunnel

final class RTTEstimatorTests: XCTestCase {
    func testInitialRTOBeforeAnySample() {
        let estimator = RTTEstimator(initialRTO: 1.0)

        XCTAssertEqual(estimator.rto, 1.0)
    }

    func testFirstSampleSetsRTOToThreeTimesRTT() {
        var estimator = RTTEstimator()

        estimator.recordSample(0.5)

        XCTAssertEqual(estimator.rto, 1.5, accuracy: 0.001)
    }

    func testRTOClampedToMinimumForTinySamples() {
        var estimator = RTTEstimator(minimumRTO: 0.2)

        estimator.recordSample(0.001)

        XCTAssertEqual(estimator.rto, 0.2)
    }

    func testRTOClampedToMaximumForHugeSamples() {
        var estimator = RTTEstimator(maximumRTO: 8.0)

        estimator.recordSample(30)

        XCTAssertEqual(estimator.rto, 8.0)
    }

    func testSmoothingConvergesAfterRepeatedSamples() {
        var estimator = RTTEstimator()
        estimator.recordSample(1.0)

        for _ in 0..<60 {
            estimator.recordSample(0.2)
        }

        XCTAssertLessThan(estimator.rto, 0.3)
    }

    func testIgnoresNonPositiveSamples() {
        var estimator = RTTEstimator(initialRTO: 1.0)

        estimator.recordSample(0)

        XCTAssertEqual(estimator.rto, 1.0)
    }
}
