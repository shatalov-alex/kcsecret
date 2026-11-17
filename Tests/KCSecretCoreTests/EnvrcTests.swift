import Testing
@testable import KCSecretCore

@Suite("Envrc")
struct EnvrcTests {
    let command = #""$HOME/.local/bin/kcsecret""#

    @Test func createsABlockInAnEmptyFile() {
        var envrc = Envrc()
        #expect(envrc.link(variable: "A", secret: "proj-a") == .added)
        #expect(envrc.link(variable: "B", secret: "proj-b") == .added)
        #expect(envrc.render(command: command) == """
            # >>> kcsecret >>>
            # Managed by kcsecret (kcsecret link / unlink / use). One Touch ID prompt loads them all.
            eval "$("$HOME/.local/bin/kcsecret" env \\
              A=proj-a \\
              B=proj-b)"
            # <<< kcsecret <<<

            """)
    }

    @Test func roundTripsAndKeepsOtherLines() {
        var first = Envrc(text: "dotenv_if_exists\nexport PORT=3000\n")
        first.link(variable: "A", secret: "a")
        let text = first.render(command: command)
        #expect(text.hasPrefix("dotenv_if_exists\nexport PORT=3000\n\n# >>> kcsecret >>>\n"))

        var second = Envrc(text: text + "layout python\n")
        #expect(second.mappings == [EnvrcMapping(variable: "A", secret: "a")])
        #expect(second.link(variable: "A", secret: "a") == .unchanged)
        #expect(second.link(variable: "A", secret: "b") == .replaced(previousSecret: "a"))
        let rendered = second.render(command: command)
        #expect(rendered.hasSuffix("  A=b)\"\n# <<< kcsecret <<<\nlayout python\n"))
        #expect(rendered.components(separatedBy: Envrc.beginMarker).count == 2)
    }

    @Test func unlinkingTheLastVariableRemovesTheBlock() {
        var envrc = Envrc(text: Envrc(text: "").withLink("A", "a").render(command: command))
        let removed = envrc.unlink(variable: "A")
        let removedAgain = envrc.unlink(variable: "A")
        #expect(removed && !removedAgain)
        #expect(envrc.render(command: command) == "")
    }

    @Test func migratesLegacyLinesIntoTheBlockWhereTheyWere() {
        var envrc = Envrc(text: """
            # direnv: secrets come from the keychain through kcsecret (Touch ID)
            export UV_PUBLISH_TOKEN="$(~/.local/bin/kcsecret get mylib-pypi-token)"
            export OTHER=1
            export GH_TOKEN="$(/opt/homebrew/bin/kcsecret get gh-token)"
            """)
        #expect(envrc.legacyLineCount == 2)
        #expect(envrc.mappings.map(\.variable) == ["UV_PUBLISH_TOKEN", "GH_TOKEN"])
        envrc.link(variable: "NEW", secret: "new")
        let lines = envrc.render(command: "kcsecret").components(separatedBy: "\n")
        #expect(lines[1] == Envrc.beginMarker)
        #expect(lines.contains("  UV_PUBLISH_TOKEN=mylib-pypi-token \\"))
        #expect(lines.contains("  NEW=new)\""))
        #expect(lines.last(where: { !$0.isEmpty }) == "export OTHER=1")
    }

    @Test func reportsOtherAssignments() {
        let envrc = Envrc(text: "export A=1\n  B=2\nexport AB=3\n")
        #expect(envrc.otherAssignments(of: "A") == ["export A=1"])
        #expect(envrc.otherAssignments(of: "B") == ["  B=2"])
        #expect(envrc.otherAssignments(of: "C").isEmpty)
    }

    @Test func keepsOtherEnvironmentsAsComments() {
        var envrc = Envrc()
        envrc.link(variable: "A", secret: "p-a")
        envrc.link(variable: "A", secret: "p-prod-a", in: "prod")
        envrc.link(variable: "B", secret: "p-prod-b", in: "prod")
        let text = envrc.render(command: "kcsecret")
        #expect(text == """
            # >>> kcsecret >>>
            # Managed by kcsecret (kcsecret link / unlink / use). One Touch ID prompt loads them all.
            eval "$(kcsecret env \\
              A=p-a)"
            # Other environments (kcsecret use ENV, export -E ENV, run -E ENV):
            # kcsecret:prod A=p-prod-a
            # kcsecret:prod B=p-prod-b
            # <<< kcsecret <<<

            """)
        let reread = Envrc(text: text)
        #expect(reread.environments == ["", "prod"])
        #expect(reread.mappings == [EnvrcMapping(variable: "A", secret: "p-a")])
        #expect(reread.mappings(in: "prod").map(\.secret) == ["p-prod-a", "p-prod-b"])
    }

    @Test func switchesTheLoadedEnvironment() {
        var envrc = Envrc()
        envrc.link(variable: "A", secret: "p-a")
        envrc.link(variable: "A", secret: "p-prod-a", in: "prod")
        envrc.use("prod")
        let text = envrc.render(command: "kcsecret")
        #expect(text.contains("# kcsecret-use prod\neval \"$(kcsecret env \\\n  A=p-prod-a)\"\n"))
        #expect(text.contains("# kcsecret:default A=p-a\n"))
        let reread = Envrc(text: text)
        #expect(reread.active == "prod")
        #expect(reread.mappings.map(\.secret) == ["p-prod-a"])
        #expect(reread.mappings(in: "").map(\.secret) == ["p-a"])
        // New links go to the loaded environment.
        var copy = reread
        copy.link(variable: "B", secret: "p-prod-b")
        #expect(copy.mappings(in: "prod").count == 2)
        // Back to default: the prod set becomes comments again.
        copy.use("")
        #expect(!copy.render(command: "kcsecret").contains("kcsecret-use"))
        #expect(Envrc(text: copy.render(command: "kcsecret")).mappings(in: "prod").count == 2)
    }

    @Test func blockWithOnlyOtherEnvironments() {
        var envrc = Envrc()
        envrc.link(variable: "A", secret: "p-prod-a", in: "prod")
        let text = envrc.render(command: "kcsecret")
        #expect(!text.contains("eval"))
        #expect(Envrc(text: text).environments == ["prod"])
        var emptied = Envrc(text: text)
        emptied.unlink(variable: "A", in: "prod")
        #expect(emptied.render(command: "kcsecret") == "")
    }

    @Test func plainVariables() {
        let envrc = Envrc(text: """
            dotenv_if_exists
            export PORT=3000
            NAME='My App'
            export URL="http://x/$HOST"
            export SHA=$(git rev-parse HEAD)
            export LIT='$not_expanded'
            layout python
            """)
        let plain = envrc.plainVariables()
        #expect(plain.variables.map(\.key) == ["PORT", "NAME", "LIT"])
        #expect(plain.variables.map(\.value) == ["3000", "My App", "$not_expanded"])
        #expect(plain.skipped == ["URL", "SHA"])
    }

    @Test func tokenParsing() {
        #expect(Envrc.mapping(fromToken: "A=b)\"") == EnvrcMapping(variable: "A", secret: "b"))
        #expect(Envrc.mapping(fromToken: "\"$HOME/x=y/kcsecret\"") == nil)
        #expect(Envrc.mapping(fromToken: "1A=b") == nil)
    }
}

extension Envrc {
    fileprivate func withLink(_ variable: String, _ secret: String) -> Envrc {
        var copy = self
        copy.link(variable: variable, secret: secret)
        return copy
    }
}
