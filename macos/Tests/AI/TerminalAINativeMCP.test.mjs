// Run with Node 22.19+ and Pi 1.1.0 installed. Uses only a controlled loopback
// MCP server, in-memory SDK state and temporary files; never requests a model.
import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createServer } from "node:http";

const packagePath = process.env.GHOSTTY_PI_PACKAGE || "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent";
const fromPackage = (value) => import(pathToFileURL(path.join(packagePath, value)));
const sdk = await fromPackage("dist/index.js");
const { Agent } = await fromPackage("node_modules/@earendil-works/pi-agent-core/dist/index.js");
const { loadExtensionFromFactory } = await fromPackage("dist/core/extensions/loader.js");
const { createMcpExtension } = await fromPackage("dist/extensions/mcp/index.js");
const { createCodemodeExtension } = await fromPackage("dist/extensions/codemode/index.js");
const { createToolSearchExtension } = await fromPackage("dist/extensions/tool-search/index.js");
const { McpOAuthCredentialStore } = await fromPackage("dist/extensions/mcp/oauth.js");
const { InMemoryAuthStorageBackend } = await fromPackage("dist/core/auth-storage.js");
const { loadMcpConfig } = await fromPackage("dist/extensions/mcp/config.js");
const { applyToolModifiers } = await fromPackage("dist/core/settings-manager.js");

async function fixtureServer() {
  const requests = [];
  const server = createServer(async (request, response) => {
    if (request.method !== "POST") { response.writeHead(405).end(); return; }
    let body = "";
    for await (const chunk of request) body += chunk;
    const message = JSON.parse(body);
    requests.push({ server: request.url.slice(1), ...message });
    if (message.id === undefined) { response.writeHead(202).end(); return; }
    let result;
    switch (message.method) {
      case "initialize": result = { protocolVersion: "2025-11-25", capabilities: { tools: {}, resources: {} }, serverInfo: { name: "ghostty-native-mcp-fixture", version: "1" } }; break;
      case "tools/list": result = { tools: [{ name: "echo", description: "Fixture evidence lookup.", inputSchema: { type: "object", properties: { fail: { type: "boolean" } } },
        outputSchema: { type: "object", properties: { ok: { type: "boolean" } } } }] }; break;
      case "resources/list": result = { resources: [] }; break;
      case "resources/templates/list": result = { resourceTemplates: [] }; break;
      case "tools/call": {
        result = { content: [{ type: "text", text: message.params.arguments?.fail ? "fixture MCP failure" : "fixture MCP evidence" }],
          structuredContent: { ok: !message.params.arguments?.fail }, isError: message.params.arguments?.fail === true, _meta: { fixtureOnly: true } };
        response.writeHead(200, { "Content-Type": "text/event-stream" });
        const progressToken = message.params._meta?.progressToken;
        if (progressToken !== undefined) response.write(`data: ${JSON.stringify({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken, progress: 1, total: 1, message: "fixture progress" } })}\n\n`);
        response.end(`data: ${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n\n`);
        return;
      }
      default: response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "Unsupported fixture method" } })); return;
    }
    response.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { server, requests, url: `http://127.0.0.1:${server.address().port}` };
}

test("Pi native MCP keeps exposure and discovery settings, emits hooked results and reports /mcp status without a model", async () => {
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), "ghostty-native-mcp-"));
  const loopback = await fixtureServer();
  const previous = { GHOSTTY_AI_WORKSPACE: process.env.GHOSTTY_AI_WORKSPACE, GHOSTTY_AI_MODE: process.env.GHOSTTY_AI_MODE,
    GHOSTTY_AI_TRUSTED_EXTENSION_PATHS: process.env.GHOSTTY_AI_TRUSTED_EXTENSION_PATHS, GHOSTTY_AI_TRUSTED_EXTENSIONS: process.env.GHOSTTY_AI_TRUSTED_EXTENSIONS };
  let session;
  let eventBus;
  try {
    const source = await fs.readFile(new URL("../../Sources/Features/AI/TerminalAIPolicy.swift", import.meta.url), "utf8");
    const extension = source.match(/static let source = #"""\n([\s\S]*?)\n    """#/)[1].replace(/^    /gm, "");
    const fixedNames = source.match(/static let toolNames = "([^"]+)"/)[1].split(",");
    const modules = path.join(temporary, "node_modules");
    await fs.mkdir(path.join(modules, "@mariozechner"), { recursive: true });
    await fs.symlink(packagePath, path.join(modules, "@mariozechner", "pi-coding-agent"));
    await fs.symlink(path.join(packagePath, "node_modules/typebox"), path.join(modules, "typebox"));
    const policyPath = path.join(temporary, "ghostty-tools.mjs");
    await fs.writeFile(policyPath, extension);
    Object.assign(process.env, { GHOSTTY_AI_WORKSPACE: temporary, GHOSTTY_AI_MODE: "assistant", GHOSTTY_AI_TRUSTED_EXTENSION_PATHS: "[]", GHOSTTY_AI_TRUSTED_EXTENSIONS: "false" });
    const runtime = sdk.createExtensionRuntime();
    eventBus = sdk.createEventBus();
    const builtinPaths = ["builtin:mcp", "builtin:codemode", "builtin:tool-search"];
    const parsed = sdk.parseArgs(["--no-extensions", "--no-builtin-tools", "--no-approve", "--extension", policyPath,
      ...builtinPaths.flatMap((name) => ["--extension", name]), "--tools", fixedNames.map((name) => `+${name}`).join(","), "--exclude-tools", "bash,powershell"]);
    assert.equal(parsed.noExtensions, true);
    assert.equal(parsed.noBuiltinTools, true);
    assert.equal(parsed.projectTrustOverride, false);
    assert.deepEqual(parsed.extensions, [policyPath, ...builtinPaths]);
    // The CLI's modifiers add fixed tools to the empty --no-builtin-tools
    // defaults without filtering the registry or overriding native defaultActive.
    const initialActiveToolNames = applyToolModifiers([], parsed.tools);
    assert.deepEqual(initialActiveToolNames, fixedNames);
    const exposures = { direct: "direct", deferred: "deferred", scripted: "codemode", hidden: "hidden" };
    const configured = Object.entries(exposures).map(([name, exposure]) => ({ name, config: { url: `${loopback.url}/${name}`, exposure }, source: "fixture:mcp.json", scope: "global" }));
    const factories = [
      (await import(pathToFileURL(policyPath))).default,
      createMcpExtension({ loadConfig: () => ({ servers: configured, errors: [], autoEnableCodemode: false }), credentials: new McpOAuthCredentialStore(new InMemoryAuthStorageBackend()), logPath: path.join(temporary, "mcp.log") }),
      createCodemodeExtension({ models: false }), createToolSearchExtension(),
    ];
    const extensions = [];
    for (let index = 0; index < factories.length; index++) extensions.push(await loadExtensionFromFactory(factories[index], temporary, eventBus, runtime, parsed.extensions[index]));
    const hooks = { calls: [], results: [] };
    const observer = await loadExtensionFromFactory((pi) => {
      pi.registerTool({ name: "mcp__forged__tool", label: "Forged MCP fixture", description: "This name has no native MCP provenance.", parameters: { type: "object", properties: {} },
        execute: async () => { throw new Error("The forged tool must never execute."); } });
      pi.on("tool_call", (event) => { hooks.calls.push(event); });
      pi.on("tool_result", (event) => { hooks.results.push(event); });
    }, temporary, eventBus, runtime, "<inline:fixture-observer>");
    extensions.push(observer);
    const empty = () => ({ skills: [], prompts: [], themes: [], agentsFiles: [], diagnostics: [] });
    const modelRuntime = new Proxy({}, { get: (_target, name) => () => { throw new Error(`The fixture must never access model runtime: ${String(name)}`); } });
    session = new sdk.AgentSession({
      agent: new Agent({ streamFn: () => { throw new Error("The fixture must never request a model."); } }),
      cwd: temporary, sessionManager: sdk.SessionManager.inMemory(temporary), settingsManager: sdk.SettingsManager.inMemory({}, { projectTrusted: false }), modelRuntime,
      initialActiveToolNames, excludedToolNames: parsed.excludeTools,
      resourceLoader: { getExtensions: () => ({ extensions, runtime, errors: [], warnings: [] }), getSkills: empty, getPrompts: empty, getThemes: empty, getAgentsFiles: empty,
        getSystemPrompt: () => "Isolated MCP fixture.", getAppendSystemPrompt: () => [], extendResources() {}, async reload() {} },
    });
    const notifications = [];
    const nativeRequests = [];
    const errors = [];
    const events = [];
    session.subscribe((event) => { events.push(event); });
    await session.bindExtensions({ mode: "rpc", onError: (error) => errors.push(error), uiContext: {
      setStatus() {}, notify: (message, notifyType) => notifications.push({ method: "notify", message, notifyType }),
      input: async (title) => { nativeRequests.push(title); assert.equal(title, "ghostty-terminal-v1"); return JSON.stringify({ output: "fixture native terminal evidence" }); },
    } });
    const runner = session.extensionRunner;
    const mcpCommand = runner.getCommand("mcp");
    assert.ok(mcpCommand, "The explicitly loaded MCP extension registers /mcp");
    await mcpCommand.handler("", runner.createCommandContext());
    assert.ok(notifications.some((item) => item.notifyType === "info" && /direct: connected/.test(item.message) && /hidden: connected/.test(item.message)));
    await runner.emit({ type: "before_agent_start", systemPromptOptions: { sections: {} } });
    const all = new Map(session.getAllTools().map((tool) => [tool.name, tool]));
    const active = new Set(session.getActiveToolNames());
    for (const name of Object.keys(exposures)) {
      const tool = all.get(`mcp__${name}__echo`);
      assert.equal(tool.sourceInfo.source, "builtin");
      assert.equal(tool.sourceInfo.path, "builtin:mcp");
      assert.equal(tool.exposure, exposures[name] === "codemode" ? "deferred" : exposures[name]);
      assert.equal(active.has(tool.name), name === "direct", "Deferred and hidden tools are not declared before discovery");
    }
    assert.equal(active.has("codemode"), false, "autoEnableCodemode=false is respected despite loading its builtin");
    assert.ok(active.has("tool_search"));
    assert.equal(all.has("bash"), false);
    assert.equal(all.has("powershell"), false);
    assert.equal(active.has("mcp__forged__tool"), false);
    assert.notEqual(all.get("mcp__forged__tool").sourceInfo.path, "builtin:mcp");
    assert.equal(all.get("list_mcp_resources").sourceInfo.path, "builtin:mcp");
    // A synthetic assistant tool call permits the SDK's real nested pipeline.
    // No prompt, stream function or model configuration is involved.
    session.agent.state.messages = [{ role: "assistant", content: [], timestamp: Date.now() }];
    const ctx = runner.createToolContext("fixture-parent", new AbortController().signal);
    const success = await ctx.executeTool("mcp__direct__echo", {});
    assert.equal(success.isError, false);
    assert.equal(success.result.details.server, "direct");
    assert.deepEqual(success.result.structuredContent.structuredContent, { ok: true });
    assert.equal(success.result.structuredContent._meta, undefined);
    const failed = await ctx.executeTool("mcp__direct__echo", { fail: true });
    assert.equal(failed.isError, true);
    assert.equal(failed.result.structuredContent.isError, true);
    assert.equal((await ctx.executeTool("list_mcp_resources", {})).isError, false);
    const hidden = await ctx.executeTool("mcp__hidden__echo", {});
    assert.equal(hidden.isError, true);
    assert.equal((await ctx.executeTool("bash", { command: "must never run" })).isError, true);
    assert.equal((await runner.emitToolCall({ type: "tool_call", toolName: "mcp__forged__tool", toolCallId: "forged", input: {} })).block, true);
    const invoke = async (name, input) => {
      assert.equal(await runner.emitToolCall({ type: "tool_call", toolName: name, toolCallId: name, input }), undefined);
      return session.agent.state.tools.find((tool) => tool.name === name).execute(name, input, new AbortController().signal);
    };
    const searched = await invoke("tool_search", { query: "deferred echo", limit: 1 });
    assert.ok(searched.details.loaded.includes("mcp__deferred__echo"));
    assert.ok(session.getActiveToolNames().includes("mcp__deferred__echo"));
    // Explicit activation here tests the native codemode execution path without
    // changing the configuration whose automatic activation remains disabled.
    session.setActiveToolsByName([...session.getActiveToolNames(), "codemode"]);
    const scripted = await invoke("codemode", { code: 'text(await tools.mcp__scripted__echo({})); text(await tools.ghostty_terminal({ operation: "read" }));' });
    assert.ok(scripted.content.some((item) => item.type === "text" && item.text.includes("fixture MCP evidence")));
    assert.deepEqual(nativeRequests, ["ghostty-terminal-v1"], "Nested Ghostty terminal access retains its native bridge");
    assert.ok(hooks.calls.some((event) => event.toolName === "mcp__scripted__echo" && event.parentToolCallId === "codemode"));
    assert.ok(hooks.results.some((event) => event.toolName === "mcp__direct__echo" && event.isError === true));
    assert.ok(events.some((event) => event.type === "tool_execution_update" && event.partialResult.content[0].text === "fixture progress"));
    assert.ok(events.some((event) => event.type === "tool_execution_end" && event.toolName === "mcp__scripted__echo" && event.parentToolCallId === "codemode"));
    assert.equal(loopback.requests.some((request) => request.server === "hidden" && request.method === "tools/call"), false);
    assert.deepEqual(errors, []);
  } finally {
    if (session) { await session.extensionRunner.emit({ type: "session_shutdown", reason: "exit" }); session.dispose(); }
    eventBus?.clear();
    for (const [name, value] of Object.entries(previous)) { if (value === undefined) delete process.env[name]; else process.env[name] = value; }
    loopback.server.closeAllConnections();
    await new Promise((resolve) => loopback.server.close(resolve));
    await fs.rm(temporary, { recursive: true, force: true });
  }
});

test("untrusted projects still load only the user MCP configuration", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "ghostty-mcp-config-"));
  try {
    const agentDir = path.join(directory, "agent");
    const cwd = path.join(directory, "project");
    await fs.mkdir(agentDir);
    await fs.mkdir(path.join(cwd, ".pi"), { recursive: true });
    await fs.writeFile(path.join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { user: { url: "http://127.0.0.1:1/user", exposure: "deferred" } } }));
    await fs.writeFile(path.join(cwd, ".pi", "mcp.json"), JSON.stringify({ mcpServers: { project: { command: "must-not-start" } } }));
    const config = loadMcpConfig({ agentDir, cwd, projectTrusted: false });
    assert.deepEqual(config.servers.map((server) => server.name), ["user"]);
    assert.equal(config.servers[0].config.exposure, "deferred");
    assert.equal(config.projectConfig, undefined);
  } finally { await fs.rm(directory, { recursive: true, force: true }); }
});
