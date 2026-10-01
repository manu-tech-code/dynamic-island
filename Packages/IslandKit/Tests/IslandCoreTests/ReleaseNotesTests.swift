import Foundation
import Testing
@testable import IslandCore

@Suite struct ReleaseNotesTests {
    @Test func gitHubGeneratedNotes() {
        let body = """
        <!-- Release notes generated using configuration in .github/release.yml at v0.5.2 -->

        ## What's Changed
        ### Features
        * One-line installer that avoids the first-launch block by @manu-tech-code in https://github.com/manu-tech-code/dynamic-island/pull/13
        ### Fixes
        * Opening Settings closes the island; version 0.7.1 by @manu-tech-code in https://github.com/manu-tech-code/dynamic-island/pull/20
        ### Chores
        * Version 0.5.2 by @manu-tech-code in https://github.com/manu-tech-code/dynamic-island/pull/14


        **Full Changelog**: https://github.com/manu-tech-code/dynamic-island/compare/v0.5.1...v0.5.2
        """
        let n = ReleaseNotes.parseBody(body)
        #expect(n.summary == nil)
        #expect(n.sections == [
            .init(title: "New", items: ["One-line installer that avoids the first-launch block"]),
            .init(title: "Fixes", items: ["Opening Settings closes the island"]),
        ]) // the version bump on its own isn't news, so "Improvements" is empty and dropped
    }

    @Test func handWrittenNotes() {
        let body = """
        Phase 3: a resizable island, a dashboard button, and responsive layouts.

        ### Width
        - One **Width** setting for the compact and the open island
        - Dashboard columns follow the width (3, 4 or 5)

        ### Also new
        - **Keyboard**: <kbd>⌥⌘I</kbd> opens the dashboard

        ### Install
        Open `DynamicIsland-0.3.0.dmg` and drag it to Applications.
        """
        let n = ReleaseNotes.parseBody(body)
        #expect(n.summary == "Phase 3: a resizable island, a dashboard button, and responsive layouts.")
        #expect(n.sections.map(\.title) == ["Width", "New"]) // "Install" has no bullets
        #expect(n.sections[0].items == ["One Width setting for the compact and the open island", "Dashboard columns follow the width (3, 4 or 5)"])
        #expect(n.sections[1].items == ["Keyboard: ⌥⌘I opens the dashboard"])
    }

    @Test func gitHubReleasesNewestFirstWithoutDraftsOrOddTags() throws {
        let json = #"""
        [
          {"tag_name":"v0.7.0","draft":false,"prerelease":false,"published_at":"2026-10-01T09:58:08Z","body":"### Features\n* Reveal animations by @a in https://x.y/pull/18"},
          {"tag_name":"v0.10.0","draft":false,"prerelease":false,"published_at":"2026-12-01T10:00:00Z","body":"### Fixes\n* A fix by @a in https://x.y/pull/30"},
          {"tag_name":"v0.8.0","draft":true,"prerelease":false,"published_at":null,"body":""},
          {"tag_name":"v0.9.0-beta","draft":false,"prerelease":true,"published_at":"2026-11-01T10:00:00Z","body":""},
          {"tag_name":"v0.4.0-installer","draft":false,"prerelease":false,"published_at":"2026-09-30T22:00:00Z","body":""}
        ]
        """#
        let notes = ReleaseNotes.parseGitHubReleases(Data(json.utf8))
        // Newest first by number (0.10 after 0.9), no draft, no pre-release, no odd tag.
        #expect(notes.map(\.version) == ["0.10.0", "0.7.0"])
        #expect(notes.first?.sections.first?.items == ["A fix"])
        #expect(notes.first?.date != nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(ReleaseNotes.isNewer("0.10.0", than: "0.9.2"))
        #expect(ReleaseNotes.isNewer("0.7.1", than: "0.7"))
        #expect(!ReleaseNotes.isNewer("0.7.0", than: "0.7"))
        #expect(!ReleaseNotes.isNewer("0.6.9", than: "0.7.0"))
    }
}
