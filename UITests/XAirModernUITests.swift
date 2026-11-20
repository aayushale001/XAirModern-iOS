import XCTest

/// End-to-end UI tests against the in-app X-Air protocol simulator (real UDP on 127.0.0.1).
final class XAirModernUITests: XCTestCase {
    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        return app
    }

    /// The controls appear during synchronization and become editable when the last node arrives.
    private func waitForReady(_ control: XCUIElement) -> Bool {
        let ready = NSPredicate(format: "exists == true AND enabled == true")
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: control)], timeout: 30) == .completed
    }

    func testConnectSyncAndToggleMute() throws {
        let app = launch(["-simulator", "XR18", "-tab", "mixer"])
        let strip = app.buttons["Select Ch 01"]
        XCTAssertTrue(waitForReady(strip), "mixer did not come online")
        let mute = app.buttons["mute-0"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        let before = mute.value as? String
        mute.tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        expectation(for: flipped, evaluatedWith: mute)
        waitForExpectations(timeout: 5)
    }

    func testChannelEQAndFaderAdjust() throws {
        let app = launch(["-simulator", "XR18", "-tab", "channel", "-strip", "0"])
        let freq = app.sliders["Freq"].firstMatch
        XCTAssertTrue(waitForReady(freq))
        bringIntoView(freq, in: app)
        let before = freq.value as? String
        let dial = freq.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        dial.press(forDuration: 0.12, thenDragTo: dial.withOffset(CGVector(dx: 0, dy: -48)))
        XCTAssertNotEqual(freq.value as? String, before, "EQ frequency knob did not change")
    }

    func testAccessibilityAuditMixer() throws {
        let app = launch(["-simulator", "XR18", "-tab", "mixer"])
        XCTAssertTrue(waitForReady(app.buttons["Select Ch 01"]))
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription, .hitRegion, .elementDetection])
    }

    func testAccessibilityAuditChannel() throws {
        let app = launch(["-simulator", "XR18", "-tab", "channel", "-strip", "0"])
        XCTAssertTrue(waitForReady(app.sliders["Freq"].firstMatch))
        try app.performAccessibilityAudit(for: .elementDetection)
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription, .hitRegion])
    }

    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            if up { app.swipeUp() } else { app.swipeDown() }
        }
    }

    /// Confirmation dialogs animate in, and a tap during presentation is dropped.
    /// Tap once the button is hittable and retry until the dialog closes.
    private func tapConfirmation(_ button: XCUIElement) {
        for _ in 0..<3 where button.waitForExistence(timeout: 5) {
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)], timeout: 3)
            button.tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button)
            if XCTWaiter.wait(for: [closed], timeout: 3) == .completed { return }
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testUSBReturnPresetAppliesToChannelOne() {
        let app = launch(["-simulator", "XR18", "-tab", "routing"])
        let tabs = app.scrollViews["routing-tabs"]
        let usb = app.buttons["USB return"]
        XCTAssertTrue(waitForReady(app.buttons["Inputs"]))
        if !usb.isHittable {
            if tabs.exists { tabs.swipeLeft() } else { app.buttons["Inputs"].swipeLeft() }
        }
        usb.tap()
        let toggle = app.buttons["/ch/01/preamp/rtnsw"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        XCTAssertEqual(toggle.value as? String, "Off")
        app.buttons["Built-in presets"].tap()
        app.descendants(matching: .any)["Chn 1-16"].firstMatch.tap()
        tapConfirmation(app.buttons["Apply preset"])
        expectation(for: NSPredicate(format: "value == %@", "On"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        capture("routing-preset")
    }

    func testRecorderOpensFolderPlaysAndReturns() {
        let app = launch(["-simulator", "XR12", "-tab", "setup", "-setup-page", "Recorder"])
        XCTAssertTrue(waitForReady(app.buttons["Play"]))
        let songs = app.buttons["SONGS"]
        bringIntoView(songs, in: app)
        songs.tap()
        let track = app.buttons["Soundcheck.wav"]
        XCTAssertTrue(track.waitForExistence(timeout: 5))
        bringIntoView(track, in: app)
        track.tap()
        let pause = app.buttons["Pause"]
        bringIntoView(pause, in: app, up: false)
        XCTAssertTrue(pause.isEnabled)
        pause.tap()
        let state = app.descendants(matching: .any)["transport-state"].firstMatch
        bringIntoView(state, in: app, up: false)
        XCTAssertEqual(state.value as? String, "PPAUSE")
        app.buttons["Next track"].tap()
        let file = app.descendants(matching: .any)["transport-file"].firstMatch
        bringIntoView(file, in: app, up: false)
        XCTAssertEqual(file.value as? String, "/SONGS/Encore.wav")
        capture("recorder-playback")
        let parent = app.buttons["Parent folder"]
        bringIntoView(parent, in: app)
        parent.tap()
        XCTAssertTrue(songs.waitForExistence(timeout: 5))
    }

    func testSelectedChannelFollowsNavigation() {
        let app = launch(["-simulator", "XR18", "-tab", "mixer"])
        let strip = app.buttons["Select Ch 02"]
        XCTAssertTrue(waitForReady(strip))
        strip.tap()
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.typeKey("2", modifierFlags: .command)
        } else {
            app.buttons["Channel"].tap()
        }
        XCTAssertTrue(app.navigationBars["Ch 02"].waitForExistence(timeout: 5))
        capture("channel-eq")
    }

    func testFXTypeChangeInLandscape() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(["-simulator", "XR18", "-tab", "effects"])
        let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Effect type,'")).firstMatch
        XCTAssertTrue(waitForReady(choose))
        choose.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("limiter\n")
        let limiter = app.buttons.matching(NSPredicate(format: "label ENDSWITH '(LIM)'")).firstMatch
        bringIntoView(limiter, in: app)
        limiter.tap()
        tapConfirmation(app.buttons["Change"])
        XCTAssertTrue(app.buttons["Effect type, LIM"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let meter = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Limiter L'")).firstMatch
        bringIntoView(meter, in: app)
        XCTAssertTrue(meter.exists)
        capture("effect-limiter-landscape")
    }
}
