//! whostty: PTY layer backed by Windows ConPTY.
//!
//! Reference: ghostty `src/pty.zig` (strategy: template — ghostty's Windows PTY
//! uses named pipes + libxev overlapped I/O; slice-0 uses anonymous pipes with
//! blocking reads on a dedicated thread, which is simpler and sufficient). See
//! PORTING.md.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("os/windows.zig");

const log = std.log.scoped(.pty);

/// Terminal size, in cells and pixels (POSIX `winsize` shape for familiarity).
pub const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

/// The platform PTY. whostty targets Windows; other platforms get an
/// unsupported stub so the package still type-checks when cross-referenced.
pub const Pty = switch (builtin.os.tag) {
    .windows => WindowsPty,
    else => UnsupportedPty,
};

/// A spawned child process attached to the pty.
pub const Child = struct {
    process: w.HANDLE,
    thread: w.HANDLE,

    pub fn deinit(self: *Child) void {
        _ = w.CloseHandle(self.thread);
        _ = w.CloseHandle(self.process);
        self.* = undefined;
    }

    pub fn kill(self: *Child) void {
        _ = w.TerminateProcess(self.process, 1);
    }
};

const WindowsPty = struct {
    /// Handle we write to; the child reads this as its stdin.
    in_write: w.HANDLE,
    /// Handle we read from; the child writes its stdout/stderr here.
    out_read: w.HANDLE,
    pseudo_console: w.HPCON,
    size: winsize,

    pub const OpenError = error{ PipeFailed, PseudoConsoleFailed };
    pub const SpawnError = error{ OutOfMemory, AttributeListFailed, CreateProcessFailed };
    pub const ReadError = error{ Eof, ReadFailed };
    pub const WriteError = error{WriteFailed};
    pub const SetSizeError = error{ResizeFailed};

    /// Open a new pty with the given initial size.
    pub fn open(size: winsize) OpenError!WindowsPty {
        // Non-inheritable: the child connects to the pty via the pseudoconsole
        // attribute (CreatePseudoConsole duplicates the ends into conhost), not
        // by inheriting these handles. Inheritable pty ends would leak into the
        // child and can confuse which console it attaches to.
        const sa: w.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(w.SECURITY_ATTRIBUTES),
            .bInheritHandle = w.FALSE,
            .lpSecurityDescriptor = null,
        };

        // Input pipe: child reads in_read, we write in_write.
        var in_read: w.HANDLE = undefined;
        var in_write: w.HANDLE = undefined;
        if (w.CreatePipe(&in_read, &in_write, @constCast(&sa), 0) == w.FALSE) {
            return error.PipeFailed;
        }
        errdefer _ = w.CloseHandle(in_write);

        // Output pipe: we read out_read, child writes out_write.
        var out_read: w.HANDLE = undefined;
        var out_write: w.HANDLE = undefined;
        if (w.CreatePipe(&out_read, &out_write, @constCast(&sa), 0) == w.FALSE) {
            _ = w.CloseHandle(in_read);
            return error.PipeFailed;
        }
        errdefer _ = w.CloseHandle(out_read);

        var pc: w.HPCON = undefined;
        const result = w.CreatePseudoConsole(coord(size), in_read, out_write, 0, &pc);

        // ConPTY duplicates the pty ends it needs, so we close our copies of
        // the child-facing ends regardless of success.
        _ = w.CloseHandle(in_read);
        _ = w.CloseHandle(out_write);

        if (result != w.S_OK) return error.PseudoConsoleFailed;

        return .{
            .in_write = in_write,
            .out_read = out_read,
            .pseudo_console = pc,
            .size = size,
        };
    }

    pub fn deinit(self: *WindowsPty) void {
        w.ClosePseudoConsole(self.pseudo_console);
        _ = w.CloseHandle(self.in_write);
        _ = w.CloseHandle(self.out_read);
        self.* = undefined;
    }

    /// Read child output. Returns error.Eof when the child closes its end.
    pub fn read(self: *WindowsPty, buf: []u8) ReadError!usize {
        var n: w.DWORD = 0;
        if (w.ReadFile(self.out_read, buf.ptr, @intCast(buf.len), &n, null) == w.FALSE) {
            // ERROR_BROKEN_PIPE (109) means the child exited.
            return if (w.GetLastError() == 109) error.Eof else error.ReadFailed;
        }
        if (n == 0) return error.Eof;
        return @intCast(n);
    }

    /// Write bytes to the child's input.
    pub fn write(self: *WindowsPty, bytes: []const u8) WriteError!usize {
        var n: w.DWORD = 0;
        if (w.WriteFile(self.in_write, bytes.ptr, @intCast(bytes.len), &n, null) == w.FALSE) {
            return error.WriteFailed;
        }
        return @intCast(n);
    }

    pub fn getSize(self: WindowsPty) winsize {
        return self.size;
    }

    pub fn setSize(self: *WindowsPty, size: winsize) SetSizeError!void {
        if (w.ResizePseudoConsole(self.pseudo_console, coord(size)) != w.S_OK) {
            return error.ResizeFailed;
        }
        self.size = size;
    }

    /// Spawn a child process attached to this pty. `command_line` is UTF-8 and
    /// is the full command line (e.g. "cmd.exe").
    pub fn spawn(
        self: *WindowsPty,
        alloc: std.mem.Allocator,
        command_line: []const u8,
    ) SpawnError!Child {
        // Query the required attribute-list size, then allocate and initialize.
        var attr_size: w.SIZE_T = 0;
        _ = w.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attr_buf = try alloc.alignedAlloc(u8, .of(usize), attr_size);
        defer alloc.free(attr_buf);
        const attr_list: *anyopaque = @ptrCast(attr_buf.ptr);

        if (w.InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == w.FALSE) {
            return error.AttributeListFailed;
        }
        defer w.DeleteProcThreadAttributeList(attr_list);

        if (w.UpdateProcThreadAttribute(
            attr_list,
            0,
            w.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            self.pseudo_console,
            @sizeOf(w.HPCON),
            null,
            null,
        ) == w.FALSE) {
            return error.AttributeListFailed;
        }

        var si: w.STARTUPINFOEXW = std.mem.zeroes(w.STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(w.STARTUPINFOEXW);
        si.lpAttributeList = attr_list;

        // CreateProcessW may mutate the command line buffer, so it must be a
        // writable, null-terminated UTF-16 string.
        const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, command_line) catch
            return error.OutOfMemory;
        defer alloc.free(cmd_w);

        var pi: w.PROCESS_INFORMATION = std.mem.zeroes(w.PROCESS_INFORMATION);
        if (w.CreateProcessW(
            null,
            cmd_w.ptr,
            null,
            null,
            w.FALSE, // pty ends are passed via the attribute list, not inherited
            w.EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            @ptrCast(&si),
            &pi,
        ) == w.FALSE) {
            return error.CreateProcessFailed;
        }

        return .{ .process = pi.hProcess, .thread = pi.hThread };
    }

    inline fn coord(size: winsize) w.COORD {
        return .{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) };
    }
};

/// Stub for non-Windows targets so the package type-checks.
const UnsupportedPty = struct {
    size: winsize,

    pub const OpenError = error{Unsupported};

    pub fn open(_: winsize) OpenError!UnsupportedPty {
        return error.Unsupported;
    }
    pub fn deinit(self: *UnsupportedPty) void {
        self.* = undefined;
    }
};
