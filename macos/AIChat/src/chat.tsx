import React, {
  useCallback, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore,
  type AnchorHTMLAttributes, type FormEvent, type KeyboardEvent, type TableHTMLAttributes,
} from "react";
import { createRoot } from "react-dom/client";
import {
  AssistantRuntimeProvider, MessagePrimitive, ThreadPrimitive, useExternalStoreRuntime,
  type ThreadMessageLike, type ToolCallMessagePartProps,
} from "@assistant-ui/react";
import { MarkdownTextPrimitive, type CodeHeaderProps } from "@assistant-ui/react-markdown";
import remarkGfm from "remark-gfm";
import "./chat.css";

type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
type ToolResult = { text?: string; detail?: string; label?: string; isRunning?: boolean; isError?: boolean };
type Content = { type: "text"; text: string } | {
  type: "tool-call"; toolCallId: string; toolName: string;
  args: { [key: string]: JSONValue }; result?: ToolResult; isError?: boolean;
};
type NativeMessage = { id: string; role: "user" | "assistant"; content: Content[] };
type CommandRecord = { id: string; command: string; systemCommand?: string; requestedCommand?: string; actualCommand?: string; commandAvailable?: boolean; directory: string; host: string; startedAt: number; duration: number; exitCode?: number; output: string; outputTruncated?: boolean; state: string };
type Attachment = { id: string; name: string; kind: string; preview: string; lineCount: number; source: string; host: string; scope?: string; truncated?: boolean; previewTruncated?: boolean };
type Workflow = { id: string; name: string; description: string; prompt: string; parameters: { name: string; defaultValue: string }[] };
type Task = { id: string; title: string; steps: { id: string; title: string; status: string; evidence: string }[]; verification?: { status: string; summary: string; evidence: string } };
type TerminalIdentity = { host: string; directory: string; isRemote: boolean; readiness: string; canRun: boolean; canSetupShell?: boolean };
type AvailableTool = { name: string; label: string; scope: string; description: string };
type Snapshot = {
  messages: NativeMessage[];
  isRunning: boolean;
  phase: string;
  status: string;
  startedAt?: number;
  approval?: { id: string; title: string; message: string; target?: string; path?: string; preview?: string };
  error?: string;
  configurationIssue?: string;
  prompt: string;
  draftRevision: number;
  context: string;
  contextTitle: string;
  suggestedCommand: string;
  suggestedExplanation: string;
  appearance: "dark" | "light";
  queuedInputs: { id: string; text: string; mode: string }[];
  terminalControlAllowed: boolean;
  automaticReviewEnabled: boolean;
  commandEntryBusy?: boolean;
  commands: CommandRecord[];
  attachments: Attachment[];
  task?: Task;
  workflows: Workflow[];
  terminalIdentity?: TerminalIdentity;
  availableTools?: AvailableTool[];
  fileWorkspace?: string;
  contextLoading: boolean;
  workflowSaveResult?: { requestID: string; success: boolean; error?: string; workflowID?: string };
};
type Action = { type: string; [key: string]: unknown };

declare global {
  interface Window {
    ghosttyAI: {
      update: (snapshot: Snapshot) => void;
      diagnostics: () => { ready: boolean; messageCount: number; isRunning: boolean; phase: string };
    };
    webkit?: { messageHandlers?: { ghosttyAI?: { postMessage: (action: Action) => void } } };
  }
}

const initialSnapshot: Snapshot = {
  messages: [], isRunning: false, phase: "idle", status: "Ready",
  prompt: "", draftRevision: 0, context: "", contextTitle: "Selected text",
  suggestedCommand: "", suggestedExplanation: "", appearance: "dark", queuedInputs: [],
  terminalControlAllowed: false,
  automaticReviewEnabled: false,
  commands: [], attachments: [], workflows: [], contextLoading: false,
};
let currentSnapshot = initialSnapshot;
let ready = false;
const listeners = new Set<() => void>();
function action(value: Action) {
  window.webkit?.messageHandlers?.ghosttyAI?.postMessage(value);
}
window.ghosttyAI = {
  update(snapshot) {
    currentSnapshot = { ...initialSnapshot, ...snapshot };
    listeners.forEach((listener) => listener());
  },
  diagnostics: () => ({ ready, messageCount: currentSnapshot.messages.length,
    isRunning: currentSnapshot.isRunning, phase: currentSnapshot.phase }),
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
};
const getSnapshot = () => currentSnapshot;

function Icon({ name, className = "" }: { name: "copy" | "stop" | "send" | "check" | "chevron" | "alert" | "terminal" | "attach" | "close"; className?: string }) {
  const paths = {
    copy: <><rect x="8" y="8" width="11" height="11" rx="2" /><path d="M15 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h3" /></>,
    stop: <rect x="6" y="6" width="12" height="12" rx="1.5" />,
    send: <><path d="m5 12 7-7 7 7M12 5v15" /></>,
    check: <path d="m5 12 4 4L19 6" />,
    chevron: <path d="m9 5 7 7-7 7" />,
    alert: <><path d="M12 8v5M12 17h.01" /><circle cx="12" cy="12" r="10" /></>,
    terminal: <><rect x="3" y="4" width="18" height="16" rx="2" /><path d="m7 9 3 3-3 3m6 0h4" /></>,
    attach: <path d="m8 12 7-7a4 4 0 0 1 6 6L10 22a6 6 0 0 1-8-8L13 3m-7 13 10-10a2 2 0 0 1 3 3L9 19" />,
    close: <path d="m6 6 12 12M6 18 18 6" />,
  };
  return <svg className={`icon ${className}`} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>;
}

function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  useEffect(() => { if (!copied) return; const timer = setTimeout(() => setCopied(false), 1800); return () => clearTimeout(timer); }, [copied]);
  return <button className="quiet-button" type="button" aria-label={label} onClick={() => {
    action({ type: "copy", text }); setCopied(true);
  }}><Icon name={copied ? "check" : "copy"} /><span>{copied ? "Copied" : label}</span></button>;
}

function CodeHeader({ language, code }: CodeHeaderProps) {
  return <div className="code-header"><span>{language || "Code"}</span><CopyButton text={code} label="Copy code" /></div>;
}
function SafeLink({ href, children, node: _node, ...props }: AnchorHTMLAttributes<HTMLAnchorElement> & { node?: unknown }) {
  // The native navigation delegate opens approved http(s) links externally.
  if (!href || !/^https?:\/\//i.test(href)) return <span>{children}</span>;
  return <a {...props} href={href}>{children}</a>;
}
function Table({ node: _node, ...props }: TableHTMLAttributes<HTMLTableElement> & { node?: unknown }) {
  return <div className="table-scroll"><table {...props} /></div>;
}
const markdownComponents = { CodeHeader, a: SafeLink, table: Table, img: () => null };
function Markdown() {
  return <MarkdownTextPrimitive className="markdown" remarkPlugins={[remarkGfm]}
    smooth={false} components={markdownComponents} />;
}
function UserText({ text }: { text: string }) { return <p className="user-text">{text}</p>; }

function formatToolArguments(args: unknown) {
  return JSON.stringify(args, (_key, value) => value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, value[key]])) : value, 2);
}

const toolLabels: Record<string, string> = {
  ghostty_propose_command: "Prepare command", ghostty_mcp: "Use MCP tools",
  ghostty_task_plan: "Update investigation", ghostty_context: "Read attached context",
  read: "Read file", ls: "List files", find: "Find files", grep: "Search files",
  edit: "Edit file", write: "Write file",
};
function ToolArguments({ args }: { args: ToolCallMessagePartProps["args"] }) {
  const [expanded, setExpanded] = useState(false);
  return <details className="tool-arguments" onToggle={(event) => setExpanded(event.currentTarget.open)}>
    <summary><Icon name="chevron" className="disclosure-icon" />Request details</summary>
    {expanded && <pre>{formatToolArguments(args)}</pre>}
  </details>;
}

function ToolCard({ toolName, args, result, isError }: ToolCallMessagePartProps) {
  const [expanded, setExpanded] = useState(false);
  const output = result as ToolResult | undefined;
  const running = output?.isRunning === true;
  const failed = isError || output?.isError;
  const detail = output?.detail || (typeof args?.command === "string" ? args.command : typeof args?.path === "string" ? args.path : "");
  const label = output?.label || (toolName === "ghostty_terminal" ? args?.operation === "read" ? "Read terminal" : "Run in terminal" : toolLabels[toolName] || toolName);
  const localFile = ["read", "ls", "find", "grep", "edit", "write"].includes(toolName);
  const target = localFile && detail ? detail.replace(/\/$/, "").split("/").pop() || detail : detail;
  const reason = typeof args?.reason === "string" ? args.reason : "";
  return <details className={`tool-card ${failed ? "tool-error" : ""}`} data-tool-name={toolName} onToggle={(event) => setExpanded(event.currentTarget.open)}>
    <summary>
      {running ? <span className="activity-dot" /> : failed ? <Icon name="alert" /> : !output ? <span className="status-dot" /> : <Icon name="check" />}
      <span className="tool-label" title={label}>{label}</span>
      {localFile && <span className="tool-target" title="File tools operate on this Mac, including when the attached terminal is using SSH.">This Mac</span>}
      <span className="tool-detail" title={detail}>{target}</span>
      <span className="tool-state">{running ? "Running" : failed ? "Failed" : !output ? "Preparing" : "Done"}</span>
      <Icon name="chevron" className="disclosure-icon" />
    </summary>
    {expanded && <div className="tool-body">
      {reason && <p className="tool-reason">{reason}</p>}
      {detail && <pre className="tool-command">{detail}</pre>}
      {output?.text ? <pre className="tool-output">{output.text}</pre> : <p className="muted">{!output ? "Waiting for execution…" : running ? "Waiting for output…" : "No output."}</p>}
      {output?.text && <CopyButton text={output.text} label="Copy output" />}
      {Object.keys(args || {}).length > 0 && <ToolArguments args={args} />}
    </div>}
  </details>;
}
const userParts = { Text: UserText };
const assistantParts = { Text: Markdown, tools: { Fallback: ToolCard }, Empty: () => null };
const convertMessage = (message: NativeMessage): ThreadMessageLike => ({ id: message.id, role: message.role, content: message.content });
function UserMessage() {
  return <MessagePrimitive.Root className="message user-message" aria-label="Your message"><div className="message-role">You</div><div className="message-content"><MessagePrimitive.Parts components={userParts} /></div></MessagePrimitive.Root>;
}
function AssistantMessage() {
  return <MessagePrimitive.Root className="message assistant-message" aria-label="AI reply"><div className="message-role">AI</div><div className="message-content"><MessagePrimitive.Parts components={assistantParts} /></div></MessagePrimitive.Root>;
}

function RunStatus({ snapshot }: { snapshot: Snapshot }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    setNow(Date.now());
    if (!snapshot.isRunning) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [snapshot.isRunning, snapshot.startedAt]);
  const seconds = snapshot.startedAt ? Math.max(0, Math.floor((now - snapshot.startedAt) / 1000)) : 0;
  const elapsed = seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  const waiting = Boolean(snapshot.approval);
  const failed = Boolean(snapshot.error);
  const label = snapshot.status || (snapshot.isRunning ? "Agent is running" : "Ready");
  return <div className={`run-bar ${snapshot.isRunning ? "active" : ""} ${failed ? "failed" : ""}`} data-phase={snapshot.phase}>
    <span className={snapshot.isRunning && !waiting ? "activity-dot" : "status-dot"} />
    <span className="run-label" title={label} role="status" aria-live="polite" aria-atomic="true">{label}</span>
    {snapshot.isRunning && snapshot.startedAt && <span className="elapsed" aria-label={`Elapsed ${elapsed}`}>{elapsed}</span>}
    {snapshot.isRunning && <button className="stop-button" type="button" disabled={snapshot.phase === "stopping"} onClick={() => action({ type: "stop" })}><Icon name="stop" />{snapshot.phase === "stopping" ? "Stopping…" : "Stop"}</button>}
  </div>;
}

function Approval({ value }: { value: NonNullable<Snapshot["approval"]> }) {
  const [answered, setAnswered] = useState(false);
  const answeredRef = useRef(false);
  const decide = (allow: boolean) => {
    if (answeredRef.current || currentSnapshot.approval?.id !== value.id) return;
    answeredRef.current = true;
    setAnswered(true);
    action({ type: "approval", id: value.id, allow });
  };
  const fileReview = value.preview !== undefined;
  const body = <>
    {(value.target || value.path) && <p className="approval-target"><span>{value.target || "This Mac"}</span>{value.path && <code>{value.path}</code>}</p>}
    <pre>{value.message}</pre>
    {value.preview !== undefined && <pre className="approval-preview" aria-label="File change preview">{value.preview}</pre>}
  </>;
  return <section className={`approval${fileReview ? " file-approval" : ""}`} aria-label="Action needs approval">
    <div className="approval-title"><Icon name="alert" /><strong>{value.title || "Approve this action"}</strong></div>
    {fileReview ? <div className="file-approval-body">{body}</div> : body}
    <div className="approval-actions"><span className="muted">{answered ? "Sending decision…" : "Agent is waiting for your decision."}</span>
      <button type="button" disabled={answered} onClick={() => decide(false)}>Decline</button>
      <button className="primary" type="button" disabled={answered} onClick={() => decide(true)}>Allow this action</button>
    </div>
  </section>;
}

function CommandSuggestion({ command, explanation, busy, canRun }: { command: string; explanation: string; busy: boolean; canRun: boolean }) {
  const [draft, setDraft] = useState(command);
  useEffect(() => setDraft(command), [command]);
  return <section className="command-suggestion" aria-label="Suggested command">
    <div className="command-title"><strong>Suggested command</strong><CopyButton text={draft} label="Copy command" /></div>
    <textarea className="command-editor" aria-label="Edit suggested command" value={draft} spellCheck={false} rows={Math.min(5, Math.max(1, draft.split("\n").length))} onChange={(event) => setDraft(event.target.value)} />
    {explanation && <p className="muted">{explanation}</p>}
    <div className="command-actions"><button type="button" disabled={busy || !draft.trim() || !canRun} onClick={() => action({ type: "command_fill", command: draft })}>Fill terminal</button><button type="button" className="primary" disabled={busy || !draft.trim() || !canRun} onClick={() => action({ type: "command_run", command: draft })}>Review & run</button></div>
    {!canRun && <p className="muted">Finish the foreground program and clear the prompt to use this command.</p>}
  </section>;
}

const taskStatus = (status: string) => ({ pending: "Pending", running: "Running", completed: "Done", failed: "Failed", passed: "Verified", unverified: "Not verified", not_verified: "Not verified", interrupted: "Interrupted" }[status] || status);
function TaskPanel({ task }: { task: Task }) {
  const completed = task.steps.filter((step) => step.status === "completed").length;
  const active = task.steps.find((step) => step.status === "running");
  return <details className="task-panel" aria-label="Troubleshooting task" open={Boolean(active)}>
    <summary><Icon name="chevron" className="disclosure-icon" /><strong title={task.title}>{task.title}</strong><span className="muted">{completed}/{task.steps.length}</span></summary>
    <ol className="task-steps">{task.steps.map((step) => <li key={step.id} data-status={step.status}><div className="task-step-line">{step.status === "running" ? <span className="activity-dot" /> : step.status === "completed" ? <Icon name="check" /> : step.status === "failed" ? <Icon name="alert" /> : <span className="status-dot" />}<span>{step.title}</span><small>{taskStatus(step.status)}</small></div>{step.evidence && <details className="evidence"><summary>Evidence</summary><pre>{step.evidence}</pre></details>}</li>)}</ol>
    {task.verification && <div className={`task-verification ${task.verification.status === "failed" ? "failed" : ""}`}><strong>Verification · {taskStatus(task.verification.status)}</strong><p>{task.verification.summary || "Verification has not completed."}</p>{task.verification.evidence && <details className="evidence"><summary>Verification evidence</summary><pre>{task.verification.evidence}</pre></details>}</div>}
  </details>;
}

function AttachmentBar({ attachments, busy }: { attachments: Attachment[]; busy: boolean }) {
  return <div className="attachments" aria-label="Project context attachments">{attachments.map((attachment) => <details key={attachment.id} className="attachment"><summary><Icon name="attach" /><span title={attachment.source}>{attachment.name}</span><small>{attachment.lineCount} lines{attachment.truncated ? " · excerpt" : ""}</small><button type="button" className="quiet-button" aria-label={`Remove ${attachment.name}`} disabled={busy} onClick={(event) => { event.preventDefault(); event.stopPropagation(); if (!currentSnapshot.isRunning && !currentSnapshot.contextLoading && currentSnapshot.attachments.some((item) => item.id === attachment.id)) action({ type: "remove_attachment", id: attachment.id }); }}><Icon name="close" /></button></summary><div className="attachment-preview"><p className="muted">{attachment.kind} · {attachment.host || "This Mac"} · {attachment.source}</p>{attachment.scope && <p className="muted">{attachment.scope}</p>}{attachment.truncated && <p className="muted">This attachment contains an excerpt; the source or output is longer.</p>}{attachment.previewTruncated && <p className="muted">Preview shortened; the full attached text is sent to AI.</p>}<pre>{attachment.preview}</pre></div></details>)}</div>;
}

function CommandBrowser({ snapshot }: { snapshot: Snapshot }) {
  const busy = snapshot.isRunning || snapshot.contextLoading;
  const [query, setQuery] = useState("");
  const [failedOnly, setFailedOnly] = useState(false);
  const commands = snapshot.commands.filter((item) => (!failedOnly || (item.exitCode !== undefined && item.exitCode !== 0)) && [item.command, item.requestedCommand, item.actualCommand, item.directory, item.host].some((value) => value?.toLowerCase().includes(query.toLowerCase())));
  const invoke = (type: string, record: CommandRecord) => {
    if (currentSnapshot.isRunning || currentSnapshot.contextLoading || !currentSnapshot.commands.some((item) => item.id === record.id)) return;
    if (type === "command_fill" && !commandAvailable(record)) return;
    action(type === "command_fill" ? { type, command: record.command, id: record.id } : { type, id: record.id });
  };
  return <section className="workbench-browser" aria-label="Command history"><div className="browser-filter"><input type="search" aria-label="Search command history" placeholder="Search command, host, or directory" value={query} onChange={(event) => setQuery(event.target.value)} /><label><input type="checkbox" checked={failedOnly} onChange={(event) => setFailedOnly(event.target.checked)} />Failed</label></div>
    {busy && <p className="muted browser-note">Finish the current task or context load before attaching or replaying a command.</p>}
    {commands.length === 0 ? <p className="muted browser-note">{snapshot.commands.length ? "No commands match this filter." : "Commands appear here after shell integration records them."}</p> : <div className="command-list">{commands.map((item) => <details className="command-record" key={item.id}><summary><code title={item.command}>{item.command || "Command text unavailable"}</code><span className={`exit-status ${item.exitCode !== undefined && item.exitCode !== 0 ? "failed" : ""}`}>{item.exitCode === undefined ? item.state : `exit ${item.exitCode}`}</span></summary><div className="command-record-body"><p className="record-metadata">{item.host || "This Mac"} · {item.directory} · {new Date(item.startedAt).toLocaleString()} · {Math.max(0, item.duration).toFixed(1)}s</p>{item.requestedCommand && <><p className="muted record-metadata">System query · fixed executable and literal arguments</p><strong>Requested command</strong><pre>{item.requestedCommand}</pre></>}{item.actualCommand && <><strong>Terminal input</strong><pre>{item.actualCommand}</pre></>}<pre>{item.output || "This command produced no captured output."}</pre>{item.outputTruncated && <p className="muted record-metadata">Captured output is truncated.</p>}<div className="command-actions"><button type="button" disabled={busy} onClick={() => invoke("command_explain", item)}>Explain</button><button type="button" disabled={busy} onClick={() => invoke("command_attach", item)}>Attach output</button><button type="button" disabled={busy || snapshot.terminalIdentity?.canRun === false || !commandAvailable(item)} onClick={() => invoke("command_fill", item)}>Fill terminal</button>{commandAvailable(item) && <CopyButton text={item.command} label="Copy" />}</div></div></details>)}</div>}
  </section>;
}
function commandAvailable(record: CommandRecord) {
  return record.commandAvailable ?? (record.command !== "Command text unavailable" && Boolean(record.command.trim()));
}

function WorkflowBrowser({ snapshot }: { snapshot: Snapshot }) {
  const busy = snapshot.isRunning || snapshot.contextLoading;
  const [query, setQuery] = useState("");
  const [selectedID, setSelectedID] = useState<string>();
  const [values, setValues] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState(false);
  const [editID, setEditID] = useState<string>();
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [prompt, setPrompt] = useState("");
  const [defaults, setDefaults] = useState<Record<string, string>>({});
  const [pendingSave, setPendingSave] = useState<string>();
  const [saveError, setSaveError] = useState<string>();
  const selected = snapshot.workflows.find((item) => item.id === selectedID);
  const parameters = [...new Set([...prompt.matchAll(/\{\{([A-Za-z_][A-Za-z0-9_-]*)\}\}/g)].map((match) => match[1]))];
  const workflows = snapshot.workflows.filter((item) => [item.name, item.description].some((value) => value.toLowerCase().includes(query.toLowerCase())));
  useEffect(() => { if (selectedID && !selected) setSelectedID(undefined); }, [selectedID, selected]);
  useEffect(() => {
    const result = snapshot.workflowSaveResult;
    if (!pendingSave || result?.requestID !== pendingSave) return;
    setPendingSave(undefined);
    if (result.success) setEditing(false);
    else setSaveError(result.error || "The workflow could not be saved. Keep your edits and try again.");
  }, [snapshot.workflowSaveResult, pendingSave]);
  const edit = (workflow?: Workflow) => {
    setPendingSave(undefined); setSaveError(undefined);
    setEditID(workflow?.id); setName(workflow?.name || ""); setDescription(workflow?.description || "");
    setPrompt(workflow?.prompt || snapshot.prompt || snapshot.messages.find((item) => item.role === "user")?.content.filter((part) => part.type === "text").map((part) => part.text).join("\n") || "");
    setDefaults(Object.fromEntries((workflow?.parameters || []).map((parameter) => [parameter.name, parameter.defaultValue]))); setEditing(true);
  };
  return <section className="workbench-browser" aria-label="Reusable workflows"><div className="browser-filter"><input type="search" aria-label="Search workflows" placeholder="Search workflows" value={query} onChange={(event) => setQuery(event.target.value)} /><button type="button" disabled={busy || Boolean(pendingSave)} onClick={() => edit()}>Save workflow</button></div>
    {editing ? <form className="workflow-form" aria-label="Edit workflow" onSubmit={(event) => { event.preventDefault(); if (pendingSave || currentSnapshot.isRunning || currentSnapshot.contextLoading || (editID && !currentSnapshot.workflows.some((item) => item.id === editID))) return; const requestID = `workflow:${Date.now()}:${Math.random().toString(36).slice(2)}`; setPendingSave(requestID); setSaveError(undefined); action({ type: "workflow_save", requestID, ...(editID ? { id: editID } : {}), name: name.trim(), description, prompt, parameters: parameters.map((parameter) => ({ name: parameter, defaultValue: defaults[parameter] || "" })) }); }}><label>Name<input required maxLength={80} disabled={Boolean(pendingSave)} value={name} onChange={(event) => setName(event.target.value)} /></label><label>Description<input maxLength={240} disabled={Boolean(pendingSave)} value={description} onChange={(event) => setDescription(event.target.value)} /></label><label>Instructions<textarea required disabled={Boolean(pendingSave)} value={prompt} onChange={(event) => setPrompt(event.target.value)} rows={4} /></label><p className="muted">Use {"{{parameter}}"} for values to fill each time. A workflow opens a draft for review.</p>{parameters.map((parameter) => <label key={parameter}>{parameter} default<input disabled={Boolean(pendingSave)} value={defaults[parameter] || ""} onChange={(event) => setDefaults({ ...defaults, [parameter]: event.target.value })} /></label>)}{saveError && <p className="failed" role="alert">{saveError}</p>}<div className="command-actions"><button type="button" onClick={() => { setPendingSave(undefined); setSaveError(undefined); setEditing(false); }}>Cancel</button><button type="submit" className="primary" disabled={busy || Boolean(pendingSave) || !name.trim() || !prompt.trim()}>{pendingSave ? "Saving…" : "Save"}</button></div></form> : <>
      {workflows.length === 0 ? <p className="muted browser-note">{snapshot.workflows.length ? "No workflows match this search." : "Save a successful task as a workflow, then reuse it with new parameters."}</p> : <div className="workflow-list">{workflows.map((item) => <div className={`workflow-row ${selectedID === item.id ? "selected" : ""}`} key={item.id}><button type="button" className="workflow-select" onClick={() => { setSelectedID(item.id); setValues(Object.fromEntries(item.parameters.map((parameter) => [parameter.name, parameter.defaultValue]))); }}><strong>{item.name}</strong><span className="muted">{item.description || item.prompt}</span></button><button type="button" className="quiet-button" disabled={busy} aria-label={`Edit ${item.name}`} onClick={() => edit(item)}>Edit</button></div>)}</div>}
      {selected && <form className="workflow-form" aria-label={`Use ${selected.name}`} onSubmit={(event) => { event.preventDefault(); if (!currentSnapshot.isRunning && !currentSnapshot.contextLoading && currentSnapshot.workflows.some((item) => item.id === selected.id)) action({ type: "workflow_use", id: selected.id, values }); }}><strong>{selected.name}</strong><pre className="workflow-prompt">{selected.prompt}</pre>{selected.parameters.map((parameter) => <label key={parameter.name}>{parameter.name}<input aria-label={`Workflow parameter ${parameter.name}`} required value={values[parameter.name] || ""} onChange={(event) => setValues({ ...values, [parameter.name]: event.target.value })} /></label>)}<div className="command-actions"><button type="button" disabled={busy} onClick={() => { if (!currentSnapshot.isRunning && !currentSnapshot.contextLoading && currentSnapshot.workflows.some((item) => item.id === selected.id)) action({ type: "workflow_remove", id: selected.id }); }}>Delete workflow</button><button type="submit" className="primary" disabled={busy}>Use as draft</button></div></form>}
    </>}
  </section>;
}

function ToolBrowser({ snapshot }: { snapshot: Snapshot }) {
  const tools = snapshot.availableTools || [];
  return <section className="workbench-browser" aria-label="Available tools">
    {snapshot.fileWorkspace && <p className="file-workspace"><span>File tools · This Mac</span><code>{snapshot.fileWorkspace}</code></p>}
    {tools.length === 0 ? <p className="muted browser-note">The agent has not reported its available tools yet.</p> : <ul className="available-tools">{tools.map((tool) => <li key={tool.name}><div><strong>{tool.label}</strong><span className="tool-target">{tool.scope}</span></div><p>{tool.description}</p><code>{tool.name}</code></li>)}</ul>}
  </section>;
}

function Workbench({ snapshot }: { snapshot: Snapshot }) {
  const [tab, setTab] = useState<"commands" | "workflows" | "tools">();
  const identity = snapshot.terminalIdentity;
  const recovery = identity?.canSetupShell && <button type="button" disabled={snapshot.contextLoading} title="At an idle shell prompt, copy integration for this shell. Finish a foreground program first. Automatic query approval never bypasses shell integration." onClick={() => { if (currentSnapshot.terminalIdentity?.canSetupShell && !currentSnapshot.contextLoading) action({ type: "ssh_setup" }); }}>Connect shell…</button>;
  return <div className="workbench"><div className="workbench-toolbar"><span className={`terminal-identity ${identity?.canRun === false ? "unready" : ""}`} title={identity ? `${identity.host} · ${identity.directory}\n${identity.readiness}` : "Attached terminal"}><Icon name="terminal" /><span>{identity?.host || "Attached terminal"}</span>{identity?.isRemote && <small>SSH</small>}</span><button type="button" aria-label="Show command history" aria-expanded={tab === "commands"} className={tab === "commands" ? "selected" : ""} onClick={() => setTab(tab === "commands" ? undefined : "commands")}>Commands{snapshot.commands.length > 0 && <small>{snapshot.commands.length}</small>}</button><button type="button" aria-label="Show workflows" aria-expanded={tab === "workflows"} className={tab === "workflows" ? "selected" : ""} onClick={() => setTab(tab === "workflows" ? undefined : "workflows")}>Workflows</button><button type="button" aria-label="Show available tools" aria-expanded={tab === "tools"} className={tab === "tools" ? "selected" : ""} onClick={() => setTab(tab === "tools" ? undefined : "tools")}>Tools</button></div>{identity?.canRun === false && <div className="terminal-readiness" role="status"><span title={identity.readiness}>{identity.canSetupShell ? "Shell prompt not verified" : identity.readiness}</span>{recovery}</div>}{tab === "commands" && <CommandBrowser snapshot={snapshot} />}{tab === "workflows" && <WorkflowBrowser snapshot={snapshot} />}{tab === "tools" && <ToolBrowser snapshot={snapshot} />}{!tab && snapshot.task && <TaskPanel task={snapshot.task} />}</div>;
}

function Chat() {
  const snapshot = useSyncExternalStore(subscribe, getSnapshot);
  const viewport = useRef<HTMLDivElement>(null);
  const composer = useRef<HTMLTextAreaElement>(null);
  const attachMenu = useRef<HTMLDetailsElement>(null);
  const stickToBottom = useRef(true);
  const [atBottom, setAtBottom] = useState(true);
  const [selectionLocked, setSelectionLocked] = useState(false);
  const visibleMessages = useRef(snapshot.messages);
  if (!selectionLocked) visibleMessages.current = snapshot.messages;
  const messages = visibleMessages.current;
  const [prompt, setPrompt] = useState(snapshot.prompt);
  const localRevision = useRef(snapshot.draftRevision);
  const composing = useRef(false);
  const deferredPrompt = useRef<{ text: string; revision: number; localRevision: number } | null>(null);
  const [runMode, setRunMode] = useState<"follow_up" | "steer">("follow_up");

  useEffect(() => {
    const onSelection = () => {
      const selection = window.getSelection();
      setSelectionLocked(Boolean(selection && !selection.isCollapsed && viewport.current?.contains(selection.anchorNode)));
    };
    document.addEventListener("selectionchange", onSelection);
    return () => document.removeEventListener("selectionchange", onSelection);
  }, []);
  useEffect(() => {
    if (snapshot.draftRevision < localRevision.current) return;
    localRevision.current = snapshot.draftRevision;
    if (composing.current) {
      deferredPrompt.current = { text: snapshot.prompt, revision: snapshot.draftRevision, localRevision: localRevision.current };
      return;
    }
    deferredPrompt.current = null;
    setPrompt(snapshot.prompt);
  }, [snapshot.prompt, snapshot.draftRevision]);
  useEffect(() => { document.documentElement.dataset.appearance = snapshot.appearance; }, [snapshot.appearance]);
  useEffect(() => {
    ready = true;
    action({ type: "ready" });
    composer.current?.focus();
    const onKey = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape" || event.isComposing || event.defaultPrevented) return;
      // Preserve an active text selection; a second Escape can hide the panel.
      const selection = window.getSelection();
      if (selection && !selection.isCollapsed) { selection.removeAllRanges(); return; }
      event.preventDefault(); action({ type: "hide" });
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  useLayoutEffect(() => {
    const node = viewport.current;
    if (node && stickToBottom.current && !selectionLocked) node.scrollTop = node.scrollHeight;
  }, [messages, snapshot.suggestedCommand, selectionLocked]);
  useLayoutEffect(() => {
    const node = composer.current;
    if (!node) return;
    const resize = () => {
      node.style.height = "auto";
      const height = node.scrollHeight;
      node.style.height = `${Math.min(100, Math.max(32, height))}px`;
      node.style.overflowY = height > 100 ? "auto" : "hidden";
    };
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(node);
    return () => observer.disconnect();
  }, [prompt]);
  const send = useCallback((text: string, steer = false) => {
    if (!text.trim() || composing.current || snapshot.contextLoading || currentSnapshot.contextLoading) return;
    if (snapshot.configurationIssue) { action({ type: "settings" }); return; }
    const revision = ++localRevision.current;
    setPrompt("");
    action({ type: "send", text, revision, mode: snapshot.isRunning ? (steer ? "steer" : runMode) : "prompt" });
  }, [snapshot.configurationIssue, snapshot.isRunning, snapshot.contextLoading, runMode]);
  const runtime = useExternalStoreRuntime<NativeMessage>({
    messages,
    isRunning: snapshot.isRunning,
    // Swift owns execution. The UI never dispatches tool calls itself.
    convertMessage,
    onNew: async (message) => { send(message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n")); },
    onCancel: async () => { action({ type: "stop" }); },
    unstable_persistsHistory: true,
  });
  const onSubmit = (event: FormEvent) => { event.preventDefault(); send(prompt); };
  const onComposerKey = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    const caret = event.currentTarget.selectionStart;
    if (event.key === "@" && !snapshot.isRunning && !snapshot.contextLoading && event.currentTarget.selectionStart === event.currentTarget.selectionEnd && (caret === 0 || /\s/.test(event.currentTarget.value[caret - 1]))) {
      event.preventDefault();
      if (attachMenu.current) {
        attachMenu.current.open = true;
        attachMenu.current.querySelector<HTMLButtonElement>("button")?.focus();
      }
      return;
    }
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send(prompt); }
    else if (event.key === "Enter" && event.shiftKey && (event.metaKey || event.ctrlKey)) { event.preventDefault(); send(prompt, true); }
  };
  return <AssistantRuntimeProvider runtime={runtime}><ThreadPrimitive.Root className={`chat${snapshot.approval?.preview !== undefined ? " has-file-approval" : ""}`}>
    <Workbench snapshot={snapshot} />
    <div className="transcript-wrap">
      <div className="transcript" role="region" aria-label="Conversation messages" ref={viewport} onScroll={() => {
        const node = viewport.current;
        if (!node) return;
        const bottom = node.scrollHeight - node.scrollTop - node.clientHeight < 48;
        stickToBottom.current = bottom; setAtBottom(bottom);
      }}>
        {messages.length === 0 && <div className="empty-state"><strong>What can I help you with?</strong><p>Explain selected output, write a command, or investigate a problem.</p></div>}
        <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
        {snapshot.suggestedCommand && <CommandSuggestion command={snapshot.suggestedCommand} explanation={snapshot.suggestedExplanation} busy={snapshot.isRunning || snapshot.contextLoading} canRun={snapshot.terminalIdentity?.canRun !== false} />}
        <div className="transcript-end" />
      </div>
      {!atBottom && <button type="button" className="jump-button" onClick={() => {
        const node = viewport.current;
        window.getSelection()?.removeAllRanges();
        stickToBottom.current = true; setAtBottom(true);
        if (node) node.scrollTop = node.scrollHeight;
      }}>Jump to latest</button>}
    </div>
    {snapshot.approval && <Approval key={snapshot.approval.id} value={snapshot.approval} />}
    {snapshot.error && <div className="error-message" role="alert"><Icon name="alert" /><span>{snapshot.error}</span></div>}
    {snapshot.configurationIssue && <div className="configuration-issue"><span>{snapshot.configurationIssue}</span><button type="button" onClick={() => action({ type: "settings" })}>Open AI settings</button></div>}
    <form className="composer" onSubmit={onSubmit}>
      {snapshot.contextLoading && <div className="context-loading" role="status"><span className="activity-dot" /><span>Loading project context…</span><button type="button" onClick={() => action({ type: "stop" })}>Cancel context load</button></div>}
      {snapshot.attachments.length > 0 && <AttachmentBar attachments={snapshot.attachments} busy={snapshot.isRunning || snapshot.contextLoading} />}
      {snapshot.queuedInputs.length > 0 && <div className="queued-inputs" aria-label="Queued messages">{snapshot.queuedInputs.map((input) => <div key={input.id} className="queued-input"><span className="queued-label">{input.mode === "steer" ? "Steer queued" : "Follow-up queued"}</span><span title={input.text}>{input.text}</span></div>)}</div>}
      <div className="composer-metadata">
        <RunStatus snapshot={snapshot} />
        {snapshot.automaticReviewEnabled ? <button type="button" className="terminal-control active" aria-label="AI automatic approval" aria-pressed="true" disabled={snapshot.isRunning || snapshot.commandEntryBusy} title="Codex Guardian reviews proposed terminal commands and local file changes and can approve them automatically. Commands still run in the attached terminal with its readiness checks. Click to turn it off for the next task. Finish or stop the current task first." onClick={() => { if (!currentSnapshot.isRunning && !currentSnapshot.commandEntryBusy) action({ type: "automatic_review", allow: false }); }}>
          <Icon name="check" /><span>AI automatic approval on</span>
        </button> : <button type="button" className={`terminal-control ${snapshot.terminalControlAllowed ? "active" : ""}`} aria-label="Auto-approve queries" aria-pressed={snapshot.terminalControlAllowed} title={`Auto-approve only verified local read-only queries in a non-root shell for this task. Changes, scripts, complex or unknown commands, SSH and root shells always need separate approval. Approving a reviewed shell command clears this setting; turn it on again for later queries. An integrated empty prompt is still required.${snapshot.terminalControlAllowed ? " Click to revoke." : " This does not approve a pending action."}`} onClick={() => action({ type: "terminal_control", allow: !snapshot.terminalControlAllowed })}>
          {snapshot.terminalControlAllowed && <Icon name="check" />}<span>Auto-approve queries{snapshot.terminalControlAllowed ? " on" : ""}</span>
        </button>}
        {snapshot.context && <details className="context-preview"><summary><Icon name="chevron" /><span>{snapshot.contextTitle || "Terminal context"}</span><span className="muted">{snapshot.context.split("\n").length} lines</span><span className="context-hint">Preview</span><button type="button" className="quiet-button" aria-label="Remove attached context" disabled={snapshot.isRunning || snapshot.contextLoading} title={snapshot.isRunning ? "Context attached to current task; stop before removing" : "Remove attached context"} onClick={(event) => { event.preventDefault(); event.stopPropagation(); if (!currentSnapshot.isRunning && !currentSnapshot.contextLoading) action({ type: "remove_context" }); }}>Remove</button></summary><pre>{snapshot.context}</pre></details>}
        {snapshot.isRunning ? <label className="run-mode"><span className="visually-hidden">While running</span><select aria-label="Message behavior while running" value={runMode} onChange={(event) => setRunMode(event.target.value as "follow_up" | "steer")}><option value="follow_up">Queue follow-up</option><option value="steer">Steer current task</option></select></label> : <span className="keyboard-hints">Enter to send · Shift+Enter for a new line · Esc to hide</span>}
      </div>
      <div className="composer-row"><details ref={attachMenu} className="attach-menu"><summary aria-label="Add project context" aria-disabled={snapshot.isRunning || snapshot.contextLoading} onClick={(event) => { if (snapshot.isRunning || snapshot.contextLoading) event.preventDefault(); }} title="Attach a file, log, Git diff, or project instructions"><Icon name="attach" /></summary><div className="attach-menu-content"><strong>Add context</strong>{[{ kind: "file", label: "File…" }, { kind: "log", label: "Log excerpt…" }, { kind: "git_diff", label: "Git diff" }, { kind: "project", label: "Project instructions" }].map((item) => <button key={item.kind} type="button" disabled={snapshot.isRunning || snapshot.contextLoading} onClick={(event) => { if (!currentSnapshot.isRunning && !currentSnapshot.contextLoading) action({ type: "attach_context", kind: item.kind }); event.currentTarget.closest("details")?.removeAttribute("open"); composer.current?.focus(); }}>{item.label}</button>)}</div></details><textarea ref={composer} aria-label="Message AI" placeholder={snapshot.isRunning ? "Add a follow-up, or steer this task…" : "Ask AI… · @ to attach context"} value={prompt} onChange={(event) => { const text = event.target.value; const revision = ++localRevision.current; setPrompt(text); action({ type: "draft", text, revision }); }} onCompositionStart={() => { composing.current = true; deferredPrompt.current = null; }} onCompositionEnd={() => {
        composing.current = false;
        const deferred = deferredPrompt.current;
        deferredPrompt.current = null;
        if (deferred && deferred.revision >= localRevision.current && deferred.localRevision === localRevision.current) {
          localRevision.current = deferred.revision;
          setPrompt(deferred.text);
        }
      }} onKeyDown={onComposerKey} rows={1} title="Enter to send · Shift+Enter for a new line · Esc to hide" />
        <button className="send-button primary" type="submit" disabled={!prompt.trim() || snapshot.contextLoading} aria-label={snapshot.configurationIssue ? "Open AI settings to send" : snapshot.isRunning ? (runMode === "steer" ? "Steer task" : "Queue follow-up") : "Send message"}><Icon name="send" /></button>
      </div>
    </form>
  </ThreadPrimitive.Root></AssistantRuntimeProvider>;
}

createRoot(document.getElementById("root")!).render(<Chat />);
