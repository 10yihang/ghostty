//! Bounded rendered command records, owned by a single terminal surface.
const CommandHistory = @This();
const std = @import("std");
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");
const Cell = @import("page.zig").Cell;
const Command = @import("osc.zig").Command.SemanticPrompt;

pub const max_records = 100;
pub const max_output_bytes = 64 * 1024;
pub const max_command_bytes = 8 * 1024;

pub const Record = struct {
    sequence: u64,
    command: ?[]const u8 = null,
    commandSource: enum { shell, screen, unknown } = .unknown,
    directory: ?[]const u8 = null,
    host: ?[]const u8 = null,
    hostIsLocal: ?bool = null,
    startedAt: f64,
    finishedAt: ?f64 = null,
    durationMs: ?u64 = null,
    exitCode: ?i32 = null,
    running: bool = true,
    output: []const u8 = "",
    outputTruncated: bool = false,
    interrupted: bool = false,

    fn deinit(self: *Record, alloc: std.mem.Allocator) void {
        if (self.command) |v| alloc.free(v);
        if (self.directory) |v| alloc.free(v);
        if (self.host) |v| alloc.free(v);
        if (self.output.len > 0) alloc.free(self.output);
    }
};

const Entry = struct {
    record: Record,
    started: std.Io.Timestamp,
};

entries: std.ArrayList(Entry) = .empty,
sequence: u64 = 0,
output_start: ?*PageList.Pin = null,
prompt_start: ?*PageList.Pin = null,

pub fn deinit(self: *CommandHistory, screen: *Screen) void {
    self.untrack(screen);
    for (self.entries.items) |*entry| entry.record.deinit(screen.alloc);
    self.entries.deinit(screen.alloc);
}

fn untrack(self: *CommandHistory, screen: *Screen) void {
    if (self.output_start) |pin| screen.pages.untrackPin(pin);
    if (self.prompt_start) |pin| screen.pages.untrackPin(pin);
    self.output_start = null;
    self.prompt_start = null;
}

pub fn start(
    self: *CommandHistory,
    screen: *Screen,
    cmd: Command,
    directory: ?[]const u8,
    host: ?[]const u8,
    host_is_local: ?bool,
) !void {
    // An unclosed command must never acquire the next command's output.
    try self.finish(screen, null, true);
    self.sequence +%= 1;
    var record: Record = .{
        .sequence = self.sequence,
        .startedAt = @as(f64, @floatFromInt(std.Io.Timestamp.now(screen.io, .real).toNanoseconds())) / 1_000_000_000,
        .hostIsLocal = host_is_local,
    };
    errdefer record.deinit(screen.alloc);
    if (directory) |v| record.directory = try screen.alloc.dupe(u8, v);
    if (host) |v| record.host = try screen.alloc.dupe(u8, v);

    var command_buffer: [max_command_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&command_buffer);
    if (cmd.writeCommandLine(&writer)) {
        if (writer.buffered().len > 0 and std.unicode.utf8ValidateSlice(writer.buffered())) {
            record.command = try screen.alloc.dupe(u8, writer.buffered());
            record.commandSource = .shell;
        }
    } else |_| {}

    var prompt_pin: ?*PageList.Pin = null;
    errdefer if (prompt_pin) |pin| screen.pages.untrackPin(pin);
    if (screen.cursor.semantic_content == .input) {
        var prompts = screen.cursor.page_pin.promptIterator(.left_up, null);
        if (prompts.next()) |prompt| {
            if (prompt.rowAndCell().row.semantic_prompt == .prompt) {
                prompt_pin = try screen.pages.trackPin(prompt);
                if (record.command == null) {
                    const rendered = try semanticText(screen, prompt, screen.cursor.page_pin.*, .input, max_command_bytes);
                    if (rendered.text.len > 0 and !rendered.truncated) {
                        record.command = rendered.text;
                        record.commandSource = .screen;
                    } else screen.alloc.free(rendered.text);
                }
            }
        }
    }

    const start_pin = try screen.pages.trackPin(screen.cursor.page_pin.*);
    errdefer screen.pages.untrackPin(start_pin);
    try self.entries.ensureUnusedCapacity(screen.alloc, 1);
    if (self.entries.items.len == max_records) {
        var old = self.entries.orderedRemove(0);
        old.record.deinit(screen.alloc);
    }
    self.entries.appendAssumeCapacity(.{ .record = record, .started = .now(screen.io, .awake) });
    self.output_start = start_pin;
    self.prompt_start = prompt_pin;
}

pub fn refresh(self: *CommandHistory, screen: *Screen) !void {
    if (self.entries.items.len == 0) return;
    const record = &self.entries.items[self.entries.items.len - 1].record;
    if (!record.running) return;
    const start_pin = self.output_start orelse return;
    // The prompt itself may have been pruned while a long command was running.
    // A tracked pin then names the oldest retained row, all of which belongs
    // to this command. Record the loss explicitly.
    var end = screen.cursor.page_pin.*;
    end.x = end.node.cols() - 1;
    if (end.before(start_pin.*)) return;
    const rendered = try semanticText(screen, start_pin.*, end, .output, max_output_bytes);
    if (record.output.len > 0) screen.alloc.free(record.output);
    record.output = rendered.text;
    record.outputTruncated = rendered.truncated or start_pin.garbage or if (self.prompt_start) |pin|
        pin.garbage or pin.rowAndCell().row.semantic_prompt != .prompt
    else
        false;
}

pub fn finish(self: *CommandHistory, screen: *Screen, exit_code: ?i32, interrupted: bool) !void {
    if (self.entries.items.len == 0) return;
    const entry = &self.entries.items[self.entries.items.len - 1];
    if (!entry.record.running) return;
    defer {
        self.untrack(screen);
        entry.record.exitCode = exit_code;
        entry.record.interrupted = interrupted;
        entry.record.running = false;
        entry.record.finishedAt = @as(f64, @floatFromInt(std.Io.Timestamp.now(screen.io, .real).toNanoseconds())) / 1_000_000_000;
        entry.record.durationMs = @intCast(@max(0, entry.started.untilNow(screen.io, .awake).toMilliseconds()));
    }
    try self.refresh(screen);
}

/// The record that can acquire a command-finished event at this instant.
/// Capture this before processing OSC D: completion makes the record inactive.
pub fn runningSequence(self: CommandHistory) u64 {
    if (self.entries.items.len == 0) return 0;
    const record = self.entries.items[self.entries.items.len - 1].record;
    return if (record.running and !record.interrupted) record.sequence else 0;
}

pub fn jsonStringify(self: CommandHistory, jws: *std.json.Stringify) !void {
    try jws.beginArray();
    for (self.entries.items) |entry| try jws.write(entry.record);
    try jws.endArray();
}

const Rendered = struct { text: []const u8, truncated: bool };

// Render only cells of the requested semantic kind. This omits continuation
// and right prompts, joins soft wraps, and never allocates the whole scrollback.
fn semanticText(screen: *Screen, start_pin: PageList.Pin, end_pin: PageList.Pin, kind: Cell.SemanticContent, limit: usize) !Rendered {
    const buffer = try screen.alloc.alloc(u8, limit);
    defer screen.alloc.free(buffer);
    var writer: std.Io.Writer = .fixed(buffer);
    var cells = start_pin.cellIterator(.right_down, end_pin);
    var previous: ?PageList.Pin = null;
    var row_has_text = false;
    var truncated = false;
    while (cells.next()) |pin| {
        if (previous) |prev| {
            if (pin.node != prev.node or pin.y != prev.y) {
                // Input blank rows are prompt decoration. Output blank rows
                // still carry meaning between two printed lines.
                while (writer.end > 0 and writer.buffer[writer.end - 1] == ' ') writer.end -= 1;
                if ((row_has_text or (kind == .output and writer.end > 0)) and !prev.rowAndCell().row.wrap) {
                    writer.writeByte('\n') catch {
                        truncated = true;
                        break;
                    };
                }
                row_has_text = false;
            }
        }
        previous = pin;
        const cell = pin.rowAndCell().cell;
        if (cell.semantic_content != kind or !cell.hasText() or cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.codepoint(), &utf8) catch continue;
        if (writer.end + len > limit) {
            truncated = true;
            break;
        }
        writer.writeAll(utf8[0..len]) catch unreachable;
        if (pin.grapheme(cell)) |extra| {
            for (extra) |cp| {
                const extra_len = std.unicode.utf8Encode(cp, &utf8) catch continue;
                if (writer.end + extra_len > limit) {
                    truncated = true;
                    break;
                }
                writer.writeAll(utf8[0..extra_len]) catch unreachable;
            }
        }
        row_has_text = true;
        if (truncated) break;
    }
    const result = std.mem.trimEnd(u8, writer.buffered(), " \r\n");
    return .{ .text = try screen.alloc.dupe(u8, result), .truncated = truncated };
}
