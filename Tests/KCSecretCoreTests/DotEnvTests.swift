import Testing
@testable import KCSecretCore

@Suite("DotEnv")
struct DotEnvTests {
    func values(_ text: String) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try DotEnv.parse(text).variables.map { ($0.key, $0.value) })
    }

    @Test func unquotedValues() throws {
        let v = try values("""
            A=1
            B = two words
            export C=3
            D=with#hash
            E=value # a comment
            F=
            """)
        #expect(v == ["A": "1", "B": "two words", "C": "3", "D": "with#hash", "E": "value", "F": ""])
    }

    @Test func singleQuotesAreLiteral() throws {
        #expect(try values(#"A='$HOME \n # not a comment'"#) == ["A": #"$HOME \n # not a comment"#])
    }

    @Test func doubleQuotesHandleEscapes() throws {
        #expect(try values(#"A="a\nb\t\"c\" \\ \$d \x""#) == ["A": "a\nb\t\"c\" \\ $d \\x"])
    }

    @Test func multiLineValues() throws {
        let result = try DotEnv.parse("""
            KEY="-----BEGIN KEY-----
            abc
            -----END KEY-----"
            NEXT=1
            """)
        #expect(result.variables.map(\.key) == ["KEY", "NEXT"])
        #expect(result.variables[0].value == "-----BEGIN KEY-----\nabc\n-----END KEY-----")
        #expect(result.variables[0].lines == 1...3)
        #expect(result.variables[1].lines == 4...4)
    }

    @Test func commentsBlankLinesAndCRLF() throws {
        let result = try DotEnv.parse("# header\r\n\r\n  # indented\r\nA=1\r\n")
        #expect(result.variables.map(\.value) == ["1"])
        #expect(result.variables[0].lines == 4...4)
    }

    @Test func lastAssignmentWinsButFirstPositionIsKept() throws {
        let result = try DotEnv.parse("A=1\nB=2\nA=3\n")
        #expect(result.variables.map(\.key) == ["A", "B"])
        #expect(result.variables.map(\.value) == ["3", "2"])
        #expect(result.entries.count == 3)
    }

    @Test func invalidLinesBecomeWarnings() throws {
        let result = try DotEnv.parse("not an assignment\nmy-key=1\nOK=1\n")
        #expect(result.variables.map(\.key) == ["OK"])
        #expect(result.warnings.map(\.line) == [1, 2])
    }

    @Test func unterminatedQuoteThrows() {
        #expect(throws: DotEnvError.self) { try DotEnv.parse("A=\"open\nB=2\n") }
        #expect(throws: DotEnvError.self) { try DotEnv.parse("A='open") }
    }

    @Test func textAfterClosingQuoteThrows() {
        #expect(throws: DotEnvError.self) { try DotEnv.parse("A=\"x\" y\n") }
    }

    @Test func removingKeepsEverythingElse() throws {
        let text = """
            # keep me
            SECRET="multi
            line"
            PORT=3000
            export TOKEN=abc
            SECRET=again

            """
        let stripped = try DotEnv.removing(keys: ["SECRET", "TOKEN"], from: text)
        #expect(stripped == "# keep me\nPORT=3000\n")
    }

    @Test func removingNothingReturnsTheTextUnchanged() throws {
        #expect(try DotEnv.removing(keys: ["X"], from: "A=1\r\n") == "A=1\r\n")
    }

    @Test(arguments: [
        "plain-token_1.2", "with space", "quote ' inside", "dollar $HOME and `cmd`",
        "line\nbreak", "back\\slash \"q\"", "hash # here", "",
    ])
    func writtenLinesReadBack(_ value: String) throws {
        let line = DotEnv.line(key: "K", value: value)
        let parsed = try DotEnv.parse(line + "\n")
        #expect(parsed.entries.map(\.value) == [value])
    }

    @Test func plainValuesStayBareForDockerRunEnvFile() {
        #expect(DotEnv.line(key: "K", value: "sk-abc_123") == "K=sk-abc_123")
        #expect(DotEnv.line(key: "K", value: "a b") == "K='a b'")
        #expect(DotEnv.line(key: "K", value: "it's") == #"K="it's""#)
    }

    @Test(arguments: ["A", "_a", "A_1", "abc"]) func validNames(_ name: String) {
        #expect(DotEnv.isVariableName(name))
    }

    @Test(arguments: ["", "1A", "A-B", "A.B", "Ä"]) func invalidNames(_ name: String) {
        #expect(!DotEnv.isVariableName(name))
    }
}
