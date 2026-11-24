import XCTest
@testable import PeekabooCore

final class TOMLTests: XCTestCase {
    private func parse(_ text: String) throws -> TOMLDocument { try TOMLDocument(parsing: text) }

    private func error(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> TOMLError? {
        do {
            _ = try parse(text)
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch let error as TOMLError {
            return error
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    func testScalarsTablesAndDottedKeys() throws {
        let doc = try parse("""
        # comment
        title = "Peekaboo" # trailing comment
        count = 1_000
        hex = 0xff
        negative = -42
        ratio = 1.25
        exp = 5e-3
        big = +inf
        on = true
        off = false

        [view]
        background = 'checker'
        a.b.c = 3
        [ "keys" . zoomed ]
        "shift+left" = "pan.edge:left"
        """)
        XCTAssertEqual(doc.value(["title"]), .string("Peekaboo"))
        XCTAssertEqual(doc.value(["count"]), .integer(1000))
        XCTAssertEqual(doc.value(["hex"]), .integer(255))
        XCTAssertEqual(doc.value(["negative"]), .integer(-42))
        XCTAssertEqual(doc.value(["ratio"]), .float(1.25))
        XCTAssertEqual(doc.value(["exp"]), .float(0.005))
        XCTAssertEqual(doc.value(["big"]), .float(.infinity))
        XCTAssertEqual(doc.value(["on"]), .bool(true))
        XCTAssertEqual(doc.value(["off"]), .bool(false))
        XCTAssertEqual(doc.value(["view", "background"]), .string("checker"))
        XCTAssertEqual(doc.value(["view", "a", "b", "c"]), .integer(3))
        XCTAssertEqual(doc.value(["keys", "zoomed", "shift+left"]), .string("pan.edge:left"))
        XCTAssertEqual(doc.tables.map(\.path), [["view"], ["keys", "zoomed"]])
        XCTAssertEqual(doc.entries.first { $0.path == ["view", "background"] }?.line, 13)
    }

    func testStringEscapes() throws {
        let doc = try parse(#"""
        a = "q\"b\\s\tt\nn\u00e9\U0001F600"
        b = 'C:\no\escape'
        c = "★"
        "." = "dot key"
        "" = "empty key"
        """#)
        XCTAssertEqual(doc.value(["a"]), .string("q\"b\\s\tt\nné😀"))
        XCTAssertEqual(doc.value(["b"]), .string(#"C:\no\escape"#))
        XCTAssertEqual(doc.value(["c"]), .string("★"))
        XCTAssertEqual(doc.value(["."]), .string("dot key"))
        XCTAssertEqual(doc.value([""]), .string("empty key"))
    }

    func testArraysSpanLinesWithCommentsAndTrailingComma() throws {
        let doc = try parse("""
        one = ["meta.rate:3", "nav.next"]
        multi = [
            "a",   # first
            'b',
            [1, 2],
        ]
        empty = []
        after = 1
        """)
        XCTAssertEqual(doc.value(["one"]), .array([.string("meta.rate:3"), .string("nav.next")]))
        XCTAssertEqual(doc.value(["multi"]), .array([.string("a"), .string("b"), .array([.integer(1), .integer(2)])]))
        XCTAssertEqual(doc.value(["empty"]), .array([]))
        XCTAssertEqual(doc.entries.last?.line, 8)
    }

    func testCRLFAndBOM() throws {
        let doc = try parse("\u{FEFF}a = 1\r\n[t]\r\nb = \"x\"\r\n")
        XCTAssertEqual(doc.value(["a"]), .integer(1))
        XCTAssertEqual(doc.value(["t", "b"]), .string("x"))
        XCTAssertEqual(doc.entries.last?.line, 3)
    }

    func testErrorsCarryLineAndColumn() {
        let cases: [(String, Int, String)] = [
            ("a = 1\nb = \n", 2, "expected a value"),
            ("a = 1\na = 2\n", 2, "duplicate key"),
            ("[t]\n[t]\n", 2, "duplicate table"),
            ("x = 1\n[x]\n", 2, "already a value"),
            ("a = \"open\n", 1, "unterminated string"),
            ("\n\na = [1, 2\n", 3, "unterminated array"),
            ("a = [1 2]\n", 1, "expected ',' or ']'"),
            ("a = {b = 1}\n", 1, "inline tables"),
            ("[[t]]\n", 1, "arrays of tables"),
            ("a = \"\"\"x\"\"\"\n", 1, "multi-line strings"),
            ("d = 1979-05-27\n", 1, "dates"),
            ("a = yes\n", 1, "strings need quotes"),
            ("a = 1 2\n", 1, "end of the line"),
            ("a = \"\\q\"\n", 1, "invalid escape"),
            ("a = 012\n", 1, "invalid number"),
            ("a = 1__0\n", 1, "invalid number"),
            ("cmd+k = 1\n", 1, "in key (quote keys"),
            ("[t\n", 1, "expected ']'"),
            ("a 1\n", 1, "expected '='"),
        ]
        for (text, line, fragment) in cases {
            guard let error = error(text) else { continue }
            XCTAssertEqual(error.line, line, text)
            XCTAssertTrue(error.message.contains(fragment), "\(text): \(error.message)")
        }
        XCTAssertEqual(error("ok = 1\nbad = nope\n")?.column, 7)
    }

    func testDeeplyNestedArraysAreAnErrorNotACrash() throws {
        func nested(_ depth: Int) -> String {
            "x = " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + "\n"
        }
        XCTAssertEqual(try parse(nested(32)).entries.count, 1)
        let tooDeep = error(nested(33))
        XCTAssertEqual(tooDeep?.message, "arrays nested more than 32 deep are not supported")
        XCTAssertEqual(tooDeep?.column, 37, "at the 33rd [")
        // 100000 levels (200 KB) overflowed even the main thread's stack; the hot reload parses on a GCD queue,
        // whose 512 KB stack 2000 levels (4 KB) overflowed.
        XCTAssertEqual(error("[keys]\n\"x\" = " + String(repeating: "[", count: 100_000) + "\n")?.line, 2)
        let parsed = expectation(description: "parsed off the main thread")
        DispatchQueue(label: "toml-test", qos: .utility).async {
            let failed: Bool
            do {
                _ = try TOMLDocument(parsing: nested(2000))
                failed = false
            } catch {
                failed = error is TOMLError
            }
            XCTAssertTrue(failed)
            parsed.fulfill()
        }
        wait(for: [parsed], timeout: 10)
    }

    func testParsesFiveKilobytesQuickly() throws {
        var text = "[keys]\n"
        for n in 0..<200 { text += "\"ctrl+x k\(n)\" = [\"meta.rate:\(n % 6)\", \"nav.next\"] # \(n)\n" }
        XCTAssertGreaterThan(text.utf8.count, 5000)
        let started = Trace.now()
        let doc = try parse(text)
        XCTAssertEqual(doc.entries.count, 200)
        XCTAssertLessThan(Trace.ms(since: started), 50)
    }
}
