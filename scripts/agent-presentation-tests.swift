import Foundation

private struct TestFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(message: message) }
}

@main
private struct AgentPresentationTests {
    static func main() throws {
        let welcome = AgentChatMessage(role: .assistant, text: "I can read and edit your C project, create files, run code, and help fix errors. Everything runs on this iPhone.")
        let user = AgentChatMessage(role: .user, text: "Replace this with binary search")
        let tool = AgentChatMessage(role: .tool, text: "Updated projects/搜索.c.", toolName: "write_file")
        let answer = AgentChatMessage(role: .assistant, text: "Done.\n\n```c\nreturn 0;\n```")
        let original = [welcome, user, tool, answer]
        let saved = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([AgentChatMessage].self, from: saved)
        try check(AgentTranscriptPresentation.visibleMessages([welcome]).isEmpty, "Legacy welcome must become an empty state")
        try check(AgentTranscriptPresentation.visibleMessages(decoded).map(\.id) == [user.id, tool.id, answer.id], "Saved history must retain message identity and order")
        try check(decoded == original, "Presentation changed saved content or tool output")
        let laterWelcome = AgentChatMessage(role: .assistant, text: welcome.text)
        try check(AgentTranscriptPresentation.visibleMessages([user, laterWelcome]).count == 2, "A real response must not be filtered as onboarding")
        try check(AgentTranscriptPresentation.visibleMessages([answer]).count == 1, "Assistant-only results must remain visible")
        print("PASS: restored history, empty state, identity, source-exact content, and real responses")

        try check(AgentToolActivity(message: tool).title == "Updated projects/搜索.c.", "Real mutation result lost its filename")
        for output in ["Safeguards are on. Turn them off in Settings to delete.", "Rejected path. Use a project-relative file.", "Could not write file: permission denied", "Change not applied. Read current contents before retrying."] {
            let activity = AgentToolActivity(message: .init(role: .tool, text: output, toolName: "write_file"))
            try check(activity.showsDetailsInitially && activity.symbol == "exclamationmark.circle", "Blocked/failed tool details must be visible")
            try check(!activity.title.hasPrefix("Updated"), "Failed edits were presented as successful")
        }
        let failedRun = AgentChatMessage(role: .tool, text: "Run finished.\nSYNTAX ERROR\nmain.c:3:0 ';' expected", toolName: "run_file")
        try check(AgentToolActivity(message: failedRun).title == "Run output", "Finishing a run must not imply it passed")
        let source = AgentChatMessage(role: .tool, text: "int secret_name = 4;\n", toolName: "read_file")
        try check(AgentToolActivity(message: source).title == "File contents", "Source contents should not become the activity label")
        let unknown = AgentToolActivity(message: .init(role: .tool, text: "opaque result", toolName: "future_tool"))
        try check(unknown.title == "Activity details", "Unknown tools need a safe presentation fallback")
        try check(AgentTranscriptPresentation.status("Working: replace text") == "Updating code…", "Internal tool names leaked into working status")
        print("PASS: Unicode paths, full tool details, blocked changes, neutral run outcomes, and future tools")

        var scroll = TranscriptScrollState()
        scroll.updateDistanceFromBottom(500) // Content growth / shorter viewport, not a gesture.
        scroll.endInteraction() // Programmatic animation or resizing becomes idle.
        try check(scroll.shouldFollow && scroll.contentChanged(), "Programmatic idle broke following the latest result")
        scroll.beginInteraction()
        scroll.updateDistanceFromBottom(300)
        scroll.endInteraction()
        scroll.updateDistanceFromBottom(450) // Compact panel while reading older history.
        scroll.endInteraction()
        try check(!scroll.shouldFollow && !scroll.contentChanged() && scroll.hasUnreadContent, "Resizing stole the reading position")
        scroll.showLatest()
        scroll.endInteraction()
        try check(scroll.shouldFollow, "Latest action failed to restore follow after resize")
        scroll.beginInteraction()
        scroll.updateDistanceFromBottom(10)
        scroll.endInteraction()
        try check(scroll.shouldFollow, "A real gesture back to the bottom must resume following")
        print("PASS: growth, programmatic idle, compact/expanded viewport, reading position, and explicit latest jump")
    }
}
