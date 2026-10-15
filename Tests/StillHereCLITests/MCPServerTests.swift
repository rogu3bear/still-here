import Darwin
import Foundation
import Testing
import StillHereCore
@testable import StillHereCLI

/// Every PID has already exited: nothing is ever signalled.
struct GoneSignalSystem: SignalSystem {
    func send(_ signal: Int32, to pid: Int32) -> Int32 { ESRCH }
    func isAlive(_ pid: Int32) -> Bool { false }
    func lookup(_ pid: Int32) -> ProcessLookup { .notFound }
}

@Suite struct MCPServerTests {
    let modernMeta: JSONValue = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:],
    ]

    func server(session: String? = "sample-session") -> MCPServer {
        let detector = FakeServerDetector()
        return MCPServer(tools: MCPTools(
            caller: session.map { AgentOwner(sessionID: $0, agentPID: nil) },
            query: ServerQuery(detector: detector),
            stopper: ServerStopper(signaller: ProcessSignaller(system: GoneSignalSystem()), exitTimeout: .milliseconds(50))
        ))
    }

    func call(_ server: MCPServer, _ request: JSONValue) async throws -> JSONValue {
        let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        return try #require(await server.handle(line: line))
    }

    @Test func legacyInitializeNegotiatesAKnownVersion() async throws {
        let response = try await call(server(), ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        #expect(response["result"]?["protocolVersion"] == "2025-06-18")
        let unknown = try await call(server(), ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2031-01-01"]])
        #expect(unknown["result"]?["protocolVersion"] == "2025-11-25")
    }

    @Test func modernRequestsAreValidatedAndCarryServerInfo() async throws {
        let discover = try await call(server(), ["jsonrpc": "2.0", "id": 2, "method": "server/discover", "params": ["_meta": modernMeta]])
        #expect(discover["result"]?["resultType"] == "complete")
        #expect(discover["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "stillhere")

        let badVersion = try await call(server(), ["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [
            "_meta": ["io.modelcontextprotocol/protocolVersion": "1999-01-01", "io.modelcontextprotocol/clientCapabilities": [:]],
        ]])
        #expect(badVersion["error"]?["code"]?.intValue == -32022)

        let missingCapabilities = try await call(server(), ["jsonrpc": "2.0", "id": 4, "method": "tools/list", "params": [
            "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"],
        ]])
        #expect(missingCapabilities["error"]?["code"]?.intValue == -32602)
    }

    @Test func notificationsGetNoResponseAndGarbageGetsParseError() async {
        #expect(await server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server().handle(line: "nope")?["error"]?["code"]?.intValue == -32700)
        #expect(await server().handle(line: #"{"jsonrpc":"2.0","id":9,"method":"nope"}"#)?["error"]?["code"]?.intValue == -32601)
    }

    @Test func listServersFiltersToTheCallingSession() async throws {
        let response = try await call(server(), ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": [
            "name": "list_servers", "arguments": ["mine": true],
        ]])
        guard case .array(let servers)? = response["result"]?["structuredContent"]?["servers"] else {
            Issue.record("no servers array"); return
        }
        #expect(servers.map { $0["port"]?.intValue } == [5173])
        #expect(response["result"]?["isError"] == false)
    }

    @Test func stopRefusesServersFromOtherSessionsUnlessAnyOwner() async throws {
        let refused = try await call(server(), ["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": [
            "name": "stop_server", "arguments": ["port": 3000],
        ]])
        #expect(refused["result"]?["isError"] == true)
        guard case .array(let content)? = refused["result"]?["content"] else { Issue.record("no content"); return }
        #expect(content.first?["text"]?.stringValue?.contains("not started by this agent session") == true)

        let noSession = try await call(server(session: nil), ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": [
            "name": "stop_server", "arguments": ["port": 5173],
        ]])
        #expect(noSession["result"]?["isError"] == true)

        let own = try await call(server(), ["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": [
            "name": "stop_server", "arguments": ["port": 5173],
        ]])
        #expect(own["result"]?["structuredContent"]?["pid"]?.intValue == 41_001)
    }

    @Test func hostileNumbersBecomeToolErrorsNotCrashes() async throws {
        for arguments: JSONValue in [["port": .number(1e30)], ["port": 5173, "pid": .number(5e9)], ["port": "5173"], [:]] {
            let response = try await call(server(), ["jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": [
                "name": "stop_server", "arguments": arguments,
            ]])
            #expect(response["result"]?["isError"] == true)
        }
        #expect(JSONValue.number(1e30).intValue == nil)
        #expect(JSONValue.number(2.5).intValue == nil)
    }

    @Test func invalidRequestsGetInvalidRequest() async {
        #expect(await server().handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)?["error"]?["code"]?.intValue == -32600)
        #expect(await server().handle(line: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)?["error"]?["code"]?.intValue == -32600)
        #expect(await server().handle(line: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)?["error"]?["code"]?.intValue == -32600)
        #expect(await server().handle(line: #"{"jsonrpc":"2.0","id":"a","method":"ping"}"#)?["result"] != nil)
    }

    @Test func discoverAlwaysIdentifiesTheServer() async throws {
        let response = try await call(server(), ["jsonrpc": "2.0", "id": 11, "method": "server/discover"])
        #expect(response["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "stillhere")
    }

    @Test func ownershipFollowsTheClaudeProcessAcrossSessionChanges() async throws {
        let detector = FakeServerDetector()
        let server = MCPServer(tools: MCPTools(
            caller: AgentOwner(sessionID: "after-clear", agentPID: 40_900),
            query: ServerQuery(detector: detector),
            stopper: ServerStopper(signaller: ProcessSignaller(system: GoneSignalSystem()), exitTimeout: .milliseconds(50))
        ))
        let response = try await call(server, ["jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": [
            "name": "list_servers", "arguments": ["mine": true],
        ]])
        guard case .array(let servers)? = response["result"]?["structuredContent"]?["servers"] else {
            Issue.record("no servers array"); return
        }
        #expect(servers.map { $0["port"]?.intValue } == [5173])
    }

    @Test func listSessionsReportsCollisionsAndServers() async throws {
        let web = GitContext(checkoutRoot: "/Users/dev/Projects/shop", branch: "feat/cart")
        let detector = FakeServerDetector()
        var tools = MCPTools(caller: nil, query: ServerQuery(detector: detector))
        tools.callerSessionPID = { nil }
        tools.scanSessions = {
            [
                AgentSession(pid: 40_900, kind: .claudeCode, startTime: .distantPast, checkouts: [web]),
                AgentSession(pid: 50_000, kind: .codex, startTime: .distantPast, checkouts: [web]),
            ]
        }
        let response = try await call(MCPServer(tools: tools), ["jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": [
            "name": "list_sessions",
        ]])
        let content = response["result"]?["structuredContent"]
        guard case .array(let sessions)? = content?["sessions"], case .array(let collisions)? = content?["collisions"] else {
            Issue.record("missing sessions or collisions"); return
        }
        #expect(sessions.first?["servers"] == [5173]) // SampleServers.vite's launcher is 40_900
        #expect(collisions.first?["sessionPIDs"] == [40_900, 50_000])
        #expect(content?["caller_pid"] == .null)
    }

    @Test func toolDefinitionsDeclareObjectSchemasAndHints() {
        for tool in MCPTools.definitions {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["annotations"]?["readOnlyHint"] != nil)
        }
        #expect(MCPTools.definitions.map { $0["name"]?.stringValue } == ["list_servers", "wait_for_server", "list_sessions", "stop_server"])
    }
}
