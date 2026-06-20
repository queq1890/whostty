//! whostty: minimal Windows API bindings not covered by std.os.windows.
//!
//! Reference: ghostty `src/os/windows.zig` (strategy: template — we only carry
//! the surface whostty needs). See PORTING.md.
//!
//! Mostly ConPTY (pseudo console) and the process-thread attribute list needed
//! to attach a child process to a pseudo console. Plain data types are reused
//! from std.os.windows.
const std = @import("std");
const builtin = @import("builtin");

pub const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const DWORD = windows.DWORD;
pub const WORD = windows.WORD;
pub const BOOL = windows.BOOL;
pub const BYTE = u8;
pub const HRESULT = windows.HRESULT;
pub const COORD = windows.COORD;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const LPCWSTR = windows.LPCWSTR;
pub const SIZE_T = windows.SIZE_T;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const S_OK: HRESULT = 0;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

/// Pseudo console handle.
pub const HPCON = HANDLE;

/// dwCreationFlags: use lpStartupInfo as a STARTUPINFOEXW.
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;

/// PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE attribute id.
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

/// STARTUPINFOEXW = STARTUPINFOW + attribute list pointer.
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

pub extern "kernel32" fn TerminateProcess(
    hProcess: HANDLE,
    uExitCode: c_uint,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *SIZE_T,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: SIZE_T,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*SIZE_T,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: *anyopaque,
) callconv(.winapi) void;

/// We declare our own CreateProcessW (rather than reuse std's) so we can pass a
/// STARTUPINFOEXW and a plain DWORD flags value.
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?LPVOID,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

// --- GUI types (not in std.os.windows) -------------------------------------

pub const HWND = windows.HWND;
pub const HDC = windows.HDC;
pub const HGLRC = windows.HGLRC;
pub const HINSTANCE = windows.HINSTANCE;
pub const HMENU = windows.HMENU;
pub const HICON = windows.HICON;
pub const HCURSOR = windows.HCURSOR;
pub const HBRUSH = windows.HBRUSH;
pub const WPARAM = windows.WPARAM;
pub const LPARAM = windows.LPARAM;
pub const LRESULT = windows.LRESULT;
pub const ATOM = windows.ATOM;
pub const UINT = c_uint;
pub const INT = c_int;
pub const POINT = windows.POINT;
pub const RECT = windows.RECT;
pub const LONG_PTR = isize;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: INT,
    cbWndExtra: INT,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD,
    nVersion: WORD,
    dwFlags: DWORD,
    iPixelType: BYTE,
    cColorBits: BYTE,
    cRedBits: BYTE,
    cRedShift: BYTE,
    cGreenBits: BYTE,
    cGreenShift: BYTE,
    cBlueBits: BYTE,
    cBlueShift: BYTE,
    cAlphaBits: BYTE,
    cAlphaShift: BYTE,
    cAccumBits: BYTE,
    cAccumRedBits: BYTE,
    cAccumGreenBits: BYTE,
    cAccumBlueBits: BYTE,
    cAccumAlphaBits: BYTE,
    cDepthBits: BYTE,
    cStencilBits: BYTE,
    cAuxBuffers: BYTE,
    iLayerType: BYTE,
    bReserved: BYTE,
    dwLayerMask: DWORD,
    dwVisibleMask: DWORD,
    dwDamageMask: DWORD,
};

// --- Window style / message / pixel-format constants -----------------------

pub const CS_OWNDC: UINT = 0x0020;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;

pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

pub const SW_SHOW: INT = 5;

pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_CREATE: UINT = 0x0001;

pub const PM_REMOVE: UINT = 0x0001;

// Virtual-key codes for reading modifier state via GetKeyState.
pub const VK_SHIFT: INT = 0x10;
pub const VK_CONTROL: INT = 0x11;
pub const VK_MENU: INT = 0x12; // Alt
pub const VK_LWIN: INT = 0x5B;
pub const VK_RWIN: INT = 0x5C;

pub const GWLP_USERDATA: INT = -21;

pub const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: BYTE = 0;
pub const PFD_MAIN_PLANE: BYTE = 0;

// --- user32 ----------------------------------------------------------------

pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?LPCWSTR,
    lpWindowName: ?LPCWSTR,
    dwStyle: DWORD,
    X: INT,
    Y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?LPVOID,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(.winapi) void;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) INT;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: INT, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: INT) callconv(.winapi) LONG_PTR;

pub const SHORT = i16;
pub extern "user32" fn GetKeyState(nVirtKey: INT) callconv(.winapi) SHORT;

// --- gdi32 -----------------------------------------------------------------

pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) INT;
pub extern "gdi32" fn SetPixelFormat(hdc: HDC, format: INT, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

// --- opengl32 (WGL) --------------------------------------------------------

pub extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// --- Clipboard (CF_UNICODETEXT) --------------------------------------------

pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const HGLOBAL = HANDLE;

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: SIZE_T) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) ?LPVOID;
pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) BOOL;

pub const ClipboardError = error{ Unsupported, OpenFailed, AllocFailed, SetFailed, OutOfMemory };

/// UTF-8 -> allocated NUL-terminated UTF-16LE. Pure (no Win32); host-testable.
pub fn utf8ToUtf16AllocZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, s);
}

/// NUL-terminated UTF-16LE -> allocated UTF-8. Pure (no Win32); host-testable.
pub fn utf16ZToUtf8Alloc(alloc: std.mem.Allocator, w: [*:0]const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.sliceTo(w, 0));
}

/// Read CF_UNICODETEXT as UTF-8. Caller owns the result. Returns null when the
/// clipboard holds no text (lets a paste keybind no-op cleanly). Win32-only;
/// link-checked but only reached from the Windows apprt.
pub fn clipboardRead(alloc: std.mem.Allocator, hwnd: HWND) ClipboardError!?[]u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    if (IsClipboardFormatAvailable(CF_UNICODETEXT) == FALSE) return null;
    if (OpenClipboard(hwnd) == FALSE) return error.OpenFailed;
    defer _ = CloseClipboard();
    const h = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const ptr = GlobalLock(h) orelse return null;
    defer _ = GlobalUnlock(h);
    const wptr: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    // Conversion failure (malformed clipboard) is treated as "nothing to paste".
    return utf16ZToUtf8Alloc(alloc, wptr) catch null;
}

/// Write UTF-8 to CF_UNICODETEXT. Allocates an HGLOBAL the OS takes ownership of
/// on success (so it is not freed then). Win32-only.
pub fn clipboardWrite(alloc: std.mem.Allocator, hwnd: HWND, utf8: []const u8) ClipboardError!void {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const wide = utf8ToUtf16AllocZ(alloc, utf8) catch return error.OutOfMemory;
    defer alloc.free(wide);

    const bytes: SIZE_T = (wide.len + 1) * @sizeOf(u16);
    const hmem = GlobalAlloc(GMEM_MOVEABLE, bytes) orelse return error.AllocFailed;
    {
        const dst = GlobalLock(hmem) orelse {
            _ = GlobalFree(hmem);
            return error.AllocFailed;
        };
        const dst_u16: [*]u16 = @ptrCast(@alignCast(dst));
        @memcpy(dst_u16[0..wide.len], wide[0..wide.len]);
        dst_u16[wide.len] = 0;
        _ = GlobalUnlock(hmem);
    }

    if (OpenClipboard(hwnd) == FALSE) {
        _ = GlobalFree(hmem);
        return error.OpenFailed;
    }
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    if (SetClipboardData(CF_UNICODETEXT, hmem) == null) {
        _ = GlobalFree(hmem); // still owned by us on failure
        return error.SetFailed;
    }
    // Success: the clipboard now owns hmem; do NOT free it.
}

test "clipboard: utf8<->utf16 round-trips, including multibyte" {
    const alloc = std.testing.allocator;
    const samples = [_][]const u8{ "hello", "caf\xc3\xa9", "\xe6\x97\xa5\xe6\x9c\xac", "a\r\nb" };
    for (samples) |s| {
        const wide = try utf8ToUtf16AllocZ(alloc, s);
        defer alloc.free(wide);
        const back = try utf16ZToUtf8Alloc(alloc, wide.ptr);
        defer alloc.free(back);
        try std.testing.expectEqualStrings(s, back);
    }
}

// WGL_ARB_create_context: request a specific GL version/profile. Resolved at
// runtime via wglGetProcAddress (it has no opengl32 import-library export). The
// renderer requires GL >= 3.3, which a bare wglCreateContext does not guarantee.
pub const WGL_CONTEXT_MAJOR_VERSION_ARB: INT = 0x2091;
pub const WGL_CONTEXT_MINOR_VERSION_ARB: INT = 0x2092;
pub const WGL_CONTEXT_FLAGS_ARB: INT = 0x2094;
pub const WGL_CONTEXT_PROFILE_MASK_ARB: INT = 0x9126;
pub const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: INT = 0x00000001;
pub const WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB: INT = 0x00000002;

/// Signature of wglCreateContextAttribsARB. `attribs` is an INT key/value list
/// terminated by 0.
pub const CreateContextAttribsFn = *const fn (HDC, ?HGLRC, [*:0]const INT) callconv(.winapi) ?HGLRC;
