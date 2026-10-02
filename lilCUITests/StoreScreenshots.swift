import XCTest
import UIKit

/// Host-driven store screenshots. Saves a native PNG into the UITest runner
/// documents at the exact moment of each frame. Do not enable in CI schemes.
@MainActor
final class StoreScreenshots: XCTestCase {
    private var app: XCUIApplication!

    func testDirectoryAppFollowsSelectedLanguage() {
        app = XCUIApplication()
        app.launchArguments = ["UITEST_STORE_SHOTS"]
        app.launch()
        openIDE()
        app.buttons["language-c"].tap()
        XCTAssertTrue(app.buttons["home-directory"].waitForExistence(timeout: 5))
        capture("ide-app-grid")
        app.buttons["home-directory"].tap()
        XCTAssertTrue(app.staticTexts["DIRECTORY"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["C workspace"].exists)
        tapBack()
        app.buttons["language-python"].tap()
        app.buttons["home-directory"].tap()
        XCTAssertTrue(app.staticTexts["Python workspace"].waitForExistence(timeout: 5))
        capture("directory-python")
    }

    func testEdsgerChatAndCoursesNavigation() {
        app = XCUIApplication()
        app.launchArguments = ["UITEST_STORE_SHOTS", "-lilc.appearance.colorway", "light", "-lilc.selected.language", "c"]
        app.launch()
        XCTAssertTrue(app.textFields["edsger-composer"].waitForExistence(timeout: 5) || app.textViews["edsger-composer"].exists, app.debugDescription)
        app.buttons["IDE"].tap()
        XCTAssertTrue(app.buttons["home-editor"].waitForExistence(timeout: 5))
        app.buttons["home-chat"].tap()
        capture("edsger-empty")
        app.buttons["edsger-courses"].tap()
        XCTAssertTrue(app.staticTexts["Lessons"].waitForExistence(timeout: 5))
        let lesson = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lesson 1 of 20'")).firstMatch
        XCTAssertTrue(lesson.exists)
        lesson.tap()
        XCTAssertTrue(app.buttons["RUN"].waitForExistence(timeout: 5))
        tapBack()
        app.buttons["IDE"].tap()
        app.buttons["home-chat"].tap()
        XCTAssertTrue(app.textFields["edsger-composer"].waitForExistence(timeout: 5) || app.textViews["edsger-composer"].exists)
        app.buttons["edsger-history"].tap()
        XCTAssertTrue(app.navigationBars["EDSGER"].waitForExistence(timeout: 5))
        app.navigationBars["EDSGER"].buttons["Done"].tap()
        app.buttons["New EDSGER chat"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("edsger-keyboard")
    }

    func testEdsgerAnswersWithBundledOfflineModel() {
        app = XCUIApplication()
        app.launchArguments = ["UITEST_STORE_SHOTS", "-lilc.appearance.colorway", "light"]
        app.launch()
        app.buttons["New EDSGER chat"].tap()
        let field = app.textFields["edsger-composer"].exists ? app.textFields["edsger-composer"] : app.textViews["edsger-composer"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("What is 2 + 2? Reply with only the number.")
        app.buttons["edsger-send"].tap()
        XCTAssertTrue(app.staticTexts["4"].waitForExistence(timeout: 240), app.debugDescription)
        capture("edsger-answer")
    }

    func testJavaScriptAndLuaLanguageSwitchAndRun() {
        app = XCUIApplication()
        app.launchArguments = ["UITEST_STORE_SHOTS"]
        app.launch()
        openIDE()
        for (id, name, source) in [("javascript", "JavaScript", "console.log("), ("lua", "Lua", "local function")] {
            let picker = app.buttons["language-" + id]
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            if !picker.isHittable { app.scrollViews.firstMatch.swipeUp() }
            picker.tap()
            capture("picker-" + id)
            let create = app.buttons["home-new-file"]
            if !create.isHittable { app.scrollViews.firstMatch.swipeDown() }
            XCTAssertTrue(create.label.contains("A single " + name + " file"))
            create.tap()
            let editor = app.textViews["code-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue((editor.value as? String)?.contains(source) == true)
            app.buttons["RUN"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'hello from lilC'")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            capture("run-" + id)
            tapBack()
        }
        let c = app.buttons["language-c"]
        if !c.isHittable { app.scrollViews.firstMatch.swipeUp() }
        c.tap()
    }

    func testPythonLanguageSwitchAndRun() {
        app = XCUIApplication()
        app.launchArguments = ["UITEST_STORE_SHOTS"]
        app.launch()
        openIDE()
        XCTAssertTrue(app.buttons["language-python"].waitForExistence(timeout: 10))
        app.buttons["language-c"].tap()
        capture("python-picker-c")
        app.buttons["language-python"].tap()
        XCTAssertTrue(app.buttons["home-new-file"].label.contains("A single Python file"), app.debugDescription)
        capture("python-picker-python")
        let newFile = app.buttons.matching(NSPredicate(format: "label CONTAINS 'New file'")).firstMatch
        XCTAssertTrue(newFile.exists, app.debugDescription)
        newFile.tap()
        let editor = app.textViews["code-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue((editor.value as? String)?.contains("print(") == true)
        XCTAssertFalse(app.buttons["FMT"].exists)
        app.buttons["RUN"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'hello from lilC'")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        capture("python-run")
        tapBack()
        if app.buttons["IDE"].exists { app.buttons["IDE"].tap() }
        XCTAssertTrue(app.buttons["language-c"].waitForExistence(timeout: 5))
        app.buttons["language-c"].tap()
        XCTAssertTrue(app.buttons["home-new-file"].label.contains("A single C file"))
    }

    func testAgentConsoleCanExpandHideAndReturnToOutput() {
        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        openIDE()

        let openEditor = app.buttons["home-editor"]
        XCTAssertTrue(openEditor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["AGENT"].exists)
        openEditor.tap()

        let agentTab = app.buttons["agent-tab"]
        XCTAssertTrue(agentTab.waitForExistence(timeout: 8), app.debugDescription)
        agentTab.tap()
        XCTAssertTrue(app.textFields["Ask about or edit this project"].waitForExistence(timeout: 5))

        app.buttons["Expand agent full screen"].tap()
        XCTAssertTrue(app.buttons["Minimize agent"].waitForExistence(timeout: 5))
        app.buttons["HIDE"].tap()
        XCTAssertTrue(app.buttons["SHOW"].waitForExistence(timeout: 5))
        app.buttons["SHOW"].tap()
        XCTAssertTrue(app.buttons["Minimize agent"].waitForExistence(timeout: 5))
        app.buttons["output-tab"].tap()
        XCTAssertTrue(app.staticTexts["Local C workspace ready."].waitForExistence(timeout: 5))
    }

    func testBundledAgentAnswersOffline() {
        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        openIDE()
        let openEditor = app.buttons["home-editor"]
        XCTAssertTrue(openEditor.waitForExistence(timeout: 10), app.debugDescription)
        openEditor.tap()
        app.buttons["agent-tab"].tap()
        let composer = app.textFields["Ask about or edit this project"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Reply with exactly the word PINEAPPLE. Do not use tools.")
        app.buttons["Send to agent"].tap()
        XCTAssertTrue(app.staticTexts["PINEAPPLE"].waitForExistence(timeout: 300), app.debugDescription)
    }

    func testAgentAsksWhatToChangeForCapabilityQuestion() {
        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        openIDE()
        let openEditor = app.buttons["home-editor"]
        XCTAssertTrue(openEditor.waitForExistence(timeout: 10), app.debugDescription)
        openEditor.tap()
        let editor = app.textViews["code-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let originalCode = editor.value as? String

        app.buttons["agent-tab"].tap()
        let composer = app.textFields["Ask about or edit this project"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Can you edit anything in my current file")
        app.buttons["Send to agent"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Yes. What would you like me to change'")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(editor.value as? String, originalCode)
    }

    func testCaptureListingScreens() {
        XCUIDevice.shared.orientation = .portrait

        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        openIDE()
        sleep(2)

        XCTAssertTrue(app.buttons["home-directory"].waitForExistence(timeout: 8), app.debugDescription)
        capture("01-home")

        XCTAssertTrue(app.buttons["home-chat"].waitForExistence(timeout: 4), app.debugDescription)
        app.buttons["home-chat"].tap()
        app.buttons["edsger-courses"].tap()
        XCTAssertTrue(app.staticTexts["Lessons"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Challenges"].waitForExistence(timeout: 4), app.debugDescription)

        let helloCard = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lesson 1 of 20'")).firstMatch
        XCTAssertTrue(helloCard.waitForExistence(timeout: 6), app.debugDescription)
        helloCard.tap()

        let run = app.buttons["RUN"]
        XCTAssertTrue(run.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(
            (app.textViews.firstMatch.value as? String)?.contains("???") == true
                || app.staticTexts.matching(NSPredicate(format: "label CONTAINS '???'")).firstMatch.waitForExistence(timeout: 4),
            app.debugDescription
        )
        dismissKeyboard()
        sleep(1)
        capture("02-lesson-blank")

        replaceEditor(with: Self.helloSolution)
        dismissKeyboard()
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        XCTAssertTrue(
            app.staticTexts["Nice."].waitForExistence(timeout: 10)
                || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'hello from lilC'")).firstMatch.waitForExistence(timeout: 2),
            app.debugDescription
        )
        capture("03-hello-run")

        sleep(3)
        replaceEditor(with: Self.syntaxErrorProgram)
        dismissKeyboard()
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        XCTAssertTrue(
            app.buttons["Jump to error"].waitForExistence(timeout: 10)
                || app.staticTexts["ERROR"].waitForExistence(timeout: 2)
                || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'SYNTAX ERROR'")).firstMatch.waitForExistence(timeout: 2),
            app.debugDescription
        )
        capture("04-error-jump")

        tapBack()
        sleep(1)
        XCTAssertTrue(app.buttons["IDE"].waitForExistence(timeout: 4), app.debugDescription)
        app.buttons["IDE"].tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 6), app.debugDescription)
        sleep(1)
        capture("05-settings")
    }

    func testCaptureSettingsOnly() {
        XCUIDevice.shared.orientation = .portrait

        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        openIDE()
        sleep(2)

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.staticTexts["PicoC"].waitForExistence(timeout: 4), app.debugDescription)
        sleep(1)
        capture("05-settings")
    }

    func testStdinStaysAboveKeyboardWhileWaiting() {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        app.buttons["edsger-courses"].tap()

        let helloCard = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lesson 1 of 20'")).firstMatch
        XCTAssertTrue(helloCard.waitForExistence(timeout: 8), app.debugDescription)
        helloCard.tap()

        let run = app.buttons["RUN"]
        XCTAssertTrue(run.waitForExistence(timeout: 8), app.debugDescription)
        replaceEditor(with: Self.stdinPromptProgram)
        dismissKeyboard()
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        assertStdinSitsAboveKeyboard()
    }

    func testStdinStaysAboveKeyboardWhenRunWithEditorKeyboardUp() {
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments.append("UITEST_STORE_SHOTS")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        app.buttons["edsger-courses"].tap()

        let helloCard = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Lesson 1 of 20'")).firstMatch
        XCTAssertTrue(helloCard.waitForExistence(timeout: 8), app.debugDescription)
        helloCard.tap()

        let run = app.buttons["RUN"]
        XCTAssertTrue(run.waitForExistence(timeout: 8), app.debugDescription)
        replaceEditor(with: Self.stdinPromptProgram)
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "Editor keyboard should stay up")
        XCTAssertTrue(run.waitForExistence(timeout: 5))
        run.tap()
        assertStdinSitsAboveKeyboard()
    }

    private func openIDE() {
        XCTAssertTrue(app.buttons["IDE"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["IDE"].tap()
    }

    private func assertStdinSitsAboveKeyboard() {
        XCTAssertTrue(
            app.otherElements["waiting-for-input"].waitForExistence(timeout: 10)
                || app.staticTexts["WAITING FOR INPUT"].waitForExistence(timeout: 2),
            app.debugDescription
        )

        let stdin = app.textFields["program-stdin"]
        XCTAssertTrue(stdin.waitForExistence(timeout: 6), app.debugDescription)
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "Keyboard should be up for stdin")

        let keyboard = app.keyboards.element
        XCTAssertLessThan(
            stdin.frame.maxY,
            keyboard.frame.minY + 12,
            "stdin field is covered by the keyboard: stdin.maxY=\(stdin.frame.maxY) keyboard.minY=\(keyboard.frame.minY)"
        )

        let prompt = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Enter your name'")).firstMatch
        if prompt.waitForExistence(timeout: 4) {
            XCTAssertLessThan(
                prompt.frame.maxY,
                keyboard.frame.minY + 12,
                "program prompt is covered by the keyboard"
            )
        }
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let data = shot.pngRepresentation
        savePNG(data, name: name)

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        UIPasteboard.general.string = "READY:\(name)"
        Thread.sleep(forTimeInterval: 0.4)
        UIPasteboard.general.string = "IDLE:\(name)"
    }

    private func savePNG(_ data: Data, name: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("store-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func replaceEditor(with text: String) {
        let editor = app.textViews["code-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8), app.debugDescription)
        editor.tap()
        sleep(1)
        editor.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 3) {
            selectAll.tap()
            sleep(1)
        } else {
            editor.tap()
            sleep(1)
            editor.press(forDuration: 1.4)
            if selectAll.waitForExistence(timeout: 3) {
                selectAll.tap()
                sleep(1)
            }
        }
        editor.typeText(text)
        sleep(1)
    }

    private func dismissKeyboard() {
        if app.keyboards.element.exists {
            app.keyboards.buttons["done"].tapIfExists()
            app.keyboards.buttons["Done"].tapIfExists()
        }
        if app.keyboards.element.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
    }

    private func tapBack() {
        let labeled = app.buttons["Back"]
        if labeled.waitForExistence(timeout: 2), labeled.isHittable {
            labeled.tap()
            return
        }
        let chevron = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'back' OR label CONTAINS[c] 'chevron'")).firstMatch
        if chevron.exists, chevron.isHittable {
            chevron.tap()
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.07)).tap()
    }

    private static let helloSolution = """
    #include <stdio.h>

    int main(void) {
        printf("hello from lilC\\n");
        return 0;
    }

    """

    private static let syntaxErrorProgram = """
    #include <stdio.h>

    int main(void) {
        printf("hello from lilC\\n"
        return 0;
    }

    """

    private static let stdinPromptProgram = """
    #include <stdio.h>

    int main(void) {
        char name[80];
        printf("=== Input / Output Test ===\\n");
        printf("Enter your name:\\n");
        scanf("%79s", name);
        printf("Hi %s\\n", name);
        return 0;
    }

    """
}

private extension XCUIElement {
    func tapIfExists(requireHittable: Bool = true) {
        guard exists else { return }
        if requireHittable, !isHittable { return }
        tap()
    }
}
