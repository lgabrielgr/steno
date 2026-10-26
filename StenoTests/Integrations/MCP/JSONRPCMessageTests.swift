import Foundation
import Testing

@testable import StenoKit

@Suite struct JSONRPCMessageTests {
    @Test("a request is one line, keys sorted, newline-terminated")
    func requestIsOneLine() throws {
        let line = try JSONRPCMessage.request(
            id: 7, method: "tools/call", params: .object(["text": .string("a\nb")])
        ).encodedLine()
        let text = try #require(String(bytes: line, encoding: .utf8))
        #expect(
            text == #"{"id":7,"jsonrpc":"2.0","method":"tools/call","params":{"text":"a\nb"}}"#
                + "\n")
        // The embedded newline is escaped: exactly one raw newline, at the end.
        #expect(line.filter { $0 == 0x0A }.count == 1)
    }

    @Test("responses, errors, server requests and notifications classify")
    func classifies() {
        let decode = { (text: String) in JSONRPCMessage.decode(line: Data(text.utf8)) }
        #expect(
            decode(#"{"jsonrpc":"2.0","id":3,"result":{}}"#)
                == .response(id: 3, result: .object([:])))
        #expect(
            decode(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"x"}}"#)
                == .errorResponse(id: 3, code: -32_602))
        #expect(
            decode(#"{"jsonrpc":"2.0","id":"s1","method":"ping"}"#)
                == .serverRequest(id: .string("s1"), method: "ping"))
        #expect(
            decode(#"{"jsonrpc":"2.0","method":"notifications/message"}"#)
                == .notification(method: "notifications/message", params: nil))
        #expect(decode("not json") == nil)
        // A string id can never match: this client only sends integers.
        #expect(decode(#"{"jsonrpc":"2.0","id":"3","result":{}}"#) == nil)
    }

    @Test("a server's ping is answered, anything else is method-not-found")
    func repliesToServerRequests() {
        let ping = JSONRPCMessage.reply(toServerRequest: .string("a"), method: "ping")
        #expect(ping["result"] == .object([:]))
        let sampling = JSONRPCMessage.reply(
            toServerRequest: .integer(4), method: "sampling/createMessage")
        #expect(sampling["error"]?["code"] == .integer(-32_601))
        #expect(sampling["id"] == .integer(4))
    }

    @Test("integers and fractions decode to different cases")
    func integersStayIntegers() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[1, 1.5]"#.utf8))
        #expect(value == .array([.integer(1), .number(1.5)]))
    }
}

@Suite struct JSONRPCFramerTests {
    @Test("lines split across chunks reassemble; CRLF and blank lines are tolerated")
    func reassembles() {
        var framer = JSONRPCFramer()
        #expect(framer.append(Data("ab".utf8)).isEmpty)
        #expect(
            framer.append(Data("c\r\n\nde".utf8)) == [.line(Data("abc".utf8))])
        #expect(framer.append(Data("f\n".utf8)) == [.line(Data("def".utf8))])
    }

    @Test("a complete line over the limit is oversized")
    func completeLineOverLimit() {
        var framer = JSONRPCFramer(limit: 4)
        #expect(framer.append(Data("ok\n12345\n".utf8)) == [.line(Data("ok".utf8)), .oversized])
    }

    @Test("an unterminated line past the limit is oversized before its newline")
    func unterminatedLineOverLimit() {
        var framer = JSONRPCFramer(limit: 4)
        #expect(framer.append(Data("123".utf8)).isEmpty)
        #expect(framer.append(Data("45".utf8)) == [.oversized])
    }
}
