import XCTest
@testable import WinSwitcherCore

final class SafetyGuardTests: XCTestCase {
    func testCircuitBreakerAllowsSingleTransientTimeout() {
        var breaker = TapCircuitBreaker(maxTimeouts: 2, windowSeconds: 10.0)
        XCTAssertFalse(breaker.isTripped)
        XCTAssertTrue(breaker.recordTimeout(at: 100.0))
        XCTAssertFalse(breaker.isTripped)
    }

    func testCircuitBreakerTripsOnRepeatedTimeoutsWithinWindow() {
        var breaker = TapCircuitBreaker(maxTimeouts: 2, windowSeconds: 10.0)
        XCTAssertTrue(breaker.recordTimeout(at: 100.0))
        XCTAssertFalse(breaker.recordTimeout(at: 105.0))
        XCTAssertTrue(breaker.isTripped)
        // Remains tripped until explicitly reset
        XCTAssertFalse(breaker.recordTimeout(at: 200.0))
        breaker.reset()
        XCTAssertFalse(breaker.isTripped)
        XCTAssertTrue(breaker.recordTimeout(at: 205.0))
    }

    func testCircuitBreakerExpiresOldTimeoutsOutsideWindow() {
        var breaker = TapCircuitBreaker(maxTimeouts: 2, windowSeconds: 10.0)
        XCTAssertTrue(breaker.recordTimeout(at: 100.0))
        // 15 seconds later -> previous timeout expired, should not trip
        XCTAssertTrue(breaker.recordTimeout(at: 115.0))
        XCTAssertFalse(breaker.isTripped)
    }

    @MainActor
    func testSystemSettingsAndExcludedBundlePassThrough() {
        let suiteName = "com.winswitcher.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.pauseInSystemSettings)
        XCTAssertTrue(settings.isBundleExcluded("com.apple.systempreferences"))
        XCTAssertTrue(settings.isBundleExcluded("com.microsoft.rdc.macos"))
        XCTAssertFalse(settings.isBundleExcluded("com.apple.Safari"))

        settings.pauseInSystemSettings = false
        XCTAssertFalse(settings.isBundleExcluded("com.apple.systempreferences"))
    }
}
