//
//  FilteredDeckUITests.swift
//  AmgiAppUITests
//
//  Verification branch only. Drives the real app against the collection
//  UITestFixtureGenerator writes: create a filtered deck from Library,
//  study it, relaunch, and check the saved settings.
//

import XCTest

final class FilteredDeckUITests: XCTestCase {
    private var app: XCUIApplication!
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments += ["-onboardingCompleted", "YES"]
        app.launch()
        if !app.navigationBars["Library"].waitForExistence(timeout: 30) {
            snap("launch-\(name)")
            dumpTree("launch-\(name)")
        }
    }

    override func tearDown() {
        if let run = testRun, run.failureCount > 0, app != nil {
            snap("failure-\(name)")
            dumpTree("failure-\(name)")
        }
        super.tearDown()
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["AMGI_SCREENSHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(Self.safe(name)).png")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: url)
        }
    }

    private func dumpTree(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["AMGI_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(Self.safe(name)).txt")
            try? app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func safe(_ name: String) -> String {
        name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }

    private func element(labelBeginsWith prefix: String, type: XCUIElement.ElementType = .button) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func waitUntil(_ element: XCUIElement, isEnabled: Bool, _ message: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: isEnabled)),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    private func searchField() -> XCUIElement {
        let field = app.textFields["Search"]
        return field.exists ? field : app.textViews["Search"]
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    private func openCreateSheet() {
        let add = app.navigationBars.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout), "Library toolbar shows the + menu")
        add.tap()
        let create = app.buttons["Create Filtered Deck…"]
        XCTAssertTrue(create.waitForExistence(timeout: timeout))
        snap("01-add-menu")
        create.tap()
        XCTAssertTrue(app.navigationBars["New Filtered Deck"].waitForExistence(timeout: timeout))
    }

    func test1_createStudyAndRelaunch() {
        launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 30))
        snap("00-library")

        openCreateSheet()
        replaceText(in: app.textFields["Deck name"], with: "Travel Study")
        replaceText(in: searchField(), with: "tag:travel")
        let reschedule = app.switches.firstMatch
        XCTAssertEqual(reschedule.value as? String, "1", "Reschedule defaults to on, like Anki")
        snap("02-form")
        app.navigationBars.buttons["Create"].tap()

        let study = app.buttons["Study now"]
        XCTAssertTrue(study.waitForExistence(timeout: timeout), "creating opens the deck")
        XCTAssertTrue(app.navigationBars["Travel Study"].waitForExistence(timeout: timeout))
        snap("03-deck-detail")
        dumpTree("03-deck-detail")

        study.tap()
        let showAnswer = element(labelBeginsWith: "Show Answer")
        XCTAssertTrue(showAnswer.waitForExistence(timeout: timeout))
        sleep(2) // let the WebView paint the template
        snap("04-question")
        dumpTree("04-question")
        let travelFronts = ["airport", "boarding pass", "luggage", "aeropuerto"]
        XCTAssertTrue(
            travelFronts.contains { app.staticTexts[$0].exists || app.webViews.staticTexts[$0].exists },
            "a not-yet-due travel card is on screen"
        )

        showAnswer.tap()
        let good = element(labelBeginsWith: "Good")
        XCTAssertTrue(good.waitForExistence(timeout: timeout))
        sleep(1)
        snap("05-answer")
        good.tap()
        sleep(1)
        snap("06-after-good")

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: timeout))
        close.tap()
        XCTAssertTrue(study.waitForExistence(timeout: timeout))
        snap("07-detail-after-study")

        // Relaunch: the deck and its settings come back from the collection.
        app.terminate()
        launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 30))
        snap("08-library-after-relaunch")
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Travel Study")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "the filtered deck survives a relaunch")
        row.tap()
        XCTAssertTrue(app.buttons["Study now"].waitForExistence(timeout: timeout))
        app.navigationBars.buttons["More"].tap()
        let edit = app.buttons["Edit Filtered Deck…"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout))
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Filtered Deck"].waitForExistence(timeout: timeout))
        XCTAssertEqual(app.textFields["Deck name"].value as? String, "Travel Study")
        XCTAssertEqual(searchField().value as? String, "tag:travel")
        XCTAssertEqual(app.switches.firstMatch.value as? String, "1")
        snap("09-edit-after-relaunch")
        app.navigationBars.buttons["Cancel"].tap()

        // Empty sends the cards home but keeps the deck; Rebuild collects again.
        let empty = app.buttons["Empty"]
        if !empty.exists { app.swipeUp() }
        XCTAssertTrue(empty.waitForExistence(timeout: timeout))
        empty.tap()
        let confirm = app.alerts.firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: timeout))
        snap("10-empty-confirm")
        confirm.buttons["Empty"].tap()
        waitUntil(app.buttons["Study now"], isEnabled: false, "an emptied deck has nothing to study")
        snap("11-after-empty")

        let rebuild = app.buttons["Rebuild"]
        XCTAssertTrue(rebuild.waitForExistence(timeout: timeout))
        rebuild.tap()
        XCTAssertTrue(element(labelBeginsWith: "Rebuilt", type: .staticText).waitForExistence(timeout: timeout))
        snap("12-after-rebuild")
        waitUntil(app.buttons["Study now"], isEnabled: true, "a rebuilt deck can be studied again")
    }

    func test2_invalidAndEmptySearchesAreReported() {
        launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 30))

        openCreateSheet()
        replaceText(in: app.textFields["Deck name"], with: "Broken")
        replaceText(in: searchField(), with: "(tag:travel")
        app.navigationBars.buttons["Create"].tap()
        let alert = app.alerts["Couldn't create filtered deck"]
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "an invalid search is reported")
        snap("20-invalid-search")
        alert.buttons["OK"].tap()

        replaceText(in: searchField(), with: "tag:does-not-exist")
        app.navigationBars.buttons["Create"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "a search matching nothing is reported")
        snap("21-no-matches")
        alert.buttons["OK"].tap()

        // Same name as an existing deck.
        replaceText(in: app.textFields["Deck name"], with: "English")
        replaceText(in: searchField(), with: "tag:shopping")
        app.navigationBars.buttons["Create"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: timeout), "a duplicate name is reported")
        snap("22-duplicate-name")
        alert.buttons["OK"].tap()

        // Empty name disables Create.
        replaceText(in: app.textFields["Deck name"], with: "")
        XCTAssertFalse(app.navigationBars.buttons["Create"].isEnabled)
        snap("23-empty-name")
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: timeout))
        snap("24-library-unchanged")
    }
}
