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

/// STARTUPINFO.dwFlags: honor the hStdInput/hStdOutput/hStdError fields. With a
/// pseudoconsole, these are left null and the ConPTY supplies the child's std
/// handles — but the flag must be set (and bInheritHandles TRUE) for the child
/// to pick up the pseudoconsole instead of the parent's console/handles.
pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;

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

/// Cancel outstanding I/O on a handle issued by any thread (lpOverlapped null =
/// all). Used to unblock the reader thread's blocking ReadFile during teardown:
/// after the shell is killed, ConPTY keeps the output pipe open (conhost holds
/// it), so the read never returns on its own and a plain join() would hang.
pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

/// System error code: a window class with this name is already registered. Window
/// classes are process-global, so the second+ `RegisterClassExW` for the shared
/// whostty class returns 0 and sets this — which the multi-window path (#86)
/// treats as success rather than a fatal error.
pub const ERROR_CLASS_ALREADY_EXISTS: DWORD = 1410;

// --- COM apartment (ole32) -------------------------------------------------
//
// COM apartment state is THREAD-LOCAL, so with thread-per-window (#86) each
// window thread that may touch apartment-bound COM must CoInitializeEx itself
// (once per process is not enough). DirectWrite font discovery uses
// DWriteCreateFactory(SHARED) which needs no apartment today, so these calls are
// a forward-looking safety net; they are cheap and idempotent (S_FALSE when the
// apartment is already initialized).

/// COINIT flag: single-threaded (apartment-threaded) apartment. The conventional
/// choice for a UI thread that owns an HWND.
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

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

// Console attach: a GUI-subsystem app has no console, so CLI output (`--help`,
// `--version`) is written by first attaching to the launching shell's console.
pub const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF; // (DWORD)-1
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5; // (DWORD)-11
pub extern "kernel32" fn AttachConsole(dwProcessId: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;

// --- Process-descendant detection (close-confirmation, #91) ------------------
// Walk a process snapshot for any process whose parent is the shell pid, to tell
// "a foreground command is running" from "sitting at a bare prompt". The shell's
// pid is derived from the child HANDLE via GetProcessId.

/// CreateToolhelp32Snapshot dwFlags: snapshot all processes.
pub const TH32CS_SNAPPROCESS: DWORD = 0x00000002;

/// PROCESSENTRY32W: one process in a toolhelp snapshot. `dwSize` MUST be set to
/// @sizeOf before Process32FirstW. We only read th32ProcessID/th32ParentProcessID.
pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize, // ULONG_PTR
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: LONG,
    dwFlags: DWORD,
    szExeFile: [260]u16,
};

pub extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
pub extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;

/// Return true if `shell_pid` has at least one direct child process still alive
/// in the snapshot. This is whostty's substitute for ghostty's
/// `cursorIsAtPrompt()` ("a foreground command is running") — without OSC133
/// shell integration we can't read the prompt state, so we ask the OS instead:
/// an idle `cmd.exe` prompt has zero children; running `vim`/`ping`/etc. forks a
/// child of the shell. On any snapshot failure we return false so a broken probe
/// never blocks shutdown (the caller then closes without prompting). Win32-only;
/// link-checked, reached only from the Windows apprt.
pub fn shellHasRunningChild(shell_pid: DWORD) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (shell_pid == 0) return false;
    const snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    defer _ = CloseHandle(snap);

    var entry: PROCESSENTRY32W = undefined;
    entry.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snap, &entry) == FALSE) return false;
    while (true) {
        // Ignore the System Idle Process (pid 0), which lists pid 0 as its own
        // parent; only a real, distinct child counts.
        if (entry.th32ParentProcessID == shell_pid and entry.th32ProcessID != 0) return true;
        if (Process32NextW(snap, &entry) == FALSE) break;
    }
    return false;
}

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
pub const LONG = windows.LONG;
/// Monitor handle (HMONITOR), used by MonitorFromWindow/GetMonitorInfoW (#91).
pub const HMONITOR = windows.HANDLE;

/// Window placement (normal/min/max rects + show state). The public field set
/// is these six; `length` MUST be set to @sizeOf before GetWindowPlacement or
/// the call fails silently. Used to save/restore exact geometry across a
/// fullscreen toggle (#91).
pub const WINDOWPLACEMENT = extern struct {
    length: UINT,
    flags: UINT,
    showCmd: UINT,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

/// Monitor geometry. `cbSize` MUST be set to @sizeOf before GetMonitorInfoW.
/// `rcMonitor` is the full monitor rect the borderless fullscreen covers (#91).
pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

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
/// The titlebar and the sizing (resize) border — the two style bits the
/// decoration toggle (#91) clears/restores. WS_OVERLAPPEDWINDOW already
/// contains both, so the toggle flips exactly these two sub-bits and leaves
/// WS_SYSMENU/WS_MINIMIZEBOX/WS_MAXIMIZEBOX intact.
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

pub const SW_SHOW: INT = 5;
/// ShowWindow nCmdShow values used by the window-state actions (#91).
pub const SW_SHOWNORMAL: INT = 1;
pub const SW_MAXIMIZE: INT = 3;
pub const SW_RESTORE: INT = 9;
/// ShowWindow SW_HIDE for the show/hide (toggle_visibility) action (#92).
pub const SW_HIDE: INT = 0;

/// SetWindowPos special hWndInsertAfter values for the float-on-top toggle (#92):
/// HWND_TOPMOST ((HWND)-1) makes the window always-on-top; HWND_NOTOPMOST
/// ((HWND)-2) clears that and re-files it below the topmost band.
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// GetWindowLongPtrW/SetWindowLongPtrW indices (#91).
pub const GWL_STYLE: INT = -16;
pub const GWL_EXSTYLE: INT = -20;

/// SetWindowPos uFlags (#91).
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;

/// MonitorFromWindow dwFlags: pick the nearest monitor (#91).
pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;

/// MessageBoxW uType flags + return values for the close-confirmation (#91).
pub const MB_YESNO: UINT = 0x00000004;
pub const MB_ICONQUESTION: UINT = 0x00000020;
pub const IDYES: INT = 6;
pub const IDNO: INT = 7;

pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_KEYDOWN: UINT = 0x0100;
/// A key was released (the WM_KEYDOWN counterpart). Used for kitty keyboard
/// `report_events` release reporting (#82).
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
/// Posted instead of WM_KEYDOWN when a key is pressed while ALT is held.
pub const WM_SYSKEYDOWN: UINT = 0x0104;
/// Posted instead of WM_KEYUP when a key is released while ALT is held.
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_CREATE: UINT = 0x0001;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_CAPTURECHANGED: UINT = 0x0215;

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
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

// --- Idle wait (frame pacing #72) ---------------------------------------------
/// All input-queue states — wake when any message (input, paint, posted) arrives.
/// The Windows 8+ value: the legacy 0x04FF plus QS_TOUCH (0x0800) and QS_POINTER
/// (0x1000), so touch/pen input also wakes the idle wait. (Our wake path uses
/// posted messages — QS_POSTMESSAGE, in both values — so this only affects
/// promptness on touch/pen, never the pty-output wake.)
pub const QS_ALLINPUT: DWORD = 0x1CFF;
pub const INFINITE: DWORD = 0xFFFFFFFF;
/// Base of the application-private message range. We post `WM_WHOSTTY_WAKE` from
/// the reader thread to wake the idle UI thread when new pty output lands.
pub const WM_USER: UINT = 0x0400;
pub const WM_WHOSTTY_WAKE: UINT = WM_USER + 1;
pub extern "user32" fn MsgWaitForMultipleObjectsEx(
    nCount: DWORD,
    pHandles: ?[*]const HANDLE,
    dwMilliseconds: DWORD,
    dwWakeMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) DWORD;

/// Block the UI thread until a window message arrives or `timeout_ms` elapses,
/// yielding the CPU while idle. Used by the frame-pacing loop to avoid spinning
/// when nothing has changed; the reader thread's `PostMessageW(WM_WHOSTTY_WAKE)`
/// and any OS input both wake it immediately.
pub fn waitForMessage(timeout_ms: u32) void {
    _ = MsgWaitForMultipleObjectsEx(0, null, timeout_ms, QS_ALLINPUT, 0);
}
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) INT;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: INT, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: INT) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;

// --- Window state: fullscreen / maximize / decorations (#91) ----------------
pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: ?HWND,
    X: INT,
    Y: INT,
    cx: INT,
    cy: INT,
    uFlags: UINT,
) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(hWnd: HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(hWnd: HWND, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(
    hWnd: ?HWND,
    lpText: [*:0]const u16,
    lpCaption: [*:0]const u16,
    uType: UINT,
) callconv(.winapi) INT;

// --- App-lifecycle + windowing actions (#92) ---------------------------------
// Bring a window to the foreground (present_terminal / show) and raise it in the
// Z-order. SetForegroundWindow may be refused cross-thread by the OS foreground
// lock (a focus-stealing guard), so callers pair it with BringWindowToTop and
// treat both as best-effort.
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn BringWindowToTop(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;

// --- Window flash (visual bell) ------------------------------------------------
pub const FLASHW_STOP: DWORD = 0;
pub const FLASHW_CAPTION: DWORD = 0x1;
pub const FLASHW_TRAY: DWORD = 0x2;
pub const FLASHW_ALL: DWORD = FLASHW_CAPTION | FLASHW_TRAY;
/// Keep flashing until the window comes to the foreground.
pub const FLASHW_TIMERNOFG: DWORD = 0xC;

pub const FLASHWINFO = extern struct {
    cbSize: UINT,
    hwnd: HWND,
    dwFlags: DWORD,
    uCount: UINT,
    dwTimeout: DWORD,
};
pub extern "user32" fn FlashWindowEx(pfwi: *const FLASHWINFO) callconv(.winapi) BOOL;

/// Visual bell: flash the caption + taskbar button until the window is focused.
/// A no-op visually if the window already has the foreground (Windows suppresses
/// the flash), which is the desired behavior — you only want to be alerted to a
/// bell in a window you aren't looking at.
pub fn flashWindow(hwnd: HWND) void {
    var info: FLASHWINFO = .{
        .cbSize = @sizeOf(FLASHWINFO),
        .hwnd = hwnd,
        .dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG,
        .uCount = 0,
        .dwTimeout = 0,
    };
    _ = FlashWindowEx(&info);
}

pub const SHORT = i16;
pub extern "user32" fn GetKeyState(nVirtKey: INT) callconv(.winapi) SHORT;

// --- Keyboard layout translation (kitty keyboard output, #82) -----------------
// Deriving the unshifted base codepoint + the actual typed text for a key press
// so it can be encoded in kitty CSI-u form. These are Windows-only and exercised
// on-device; the host tests cover the pure encoding logic separately.

/// Opaque keyboard-layout handle (HKL).
pub const HKL = HANDLE;

/// uMapType for MapVirtualKeyW: translate a virtual key to its (unshifted)
/// character value. The result has the high bit (0x80000000) set for dead keys;
/// mask it off and lowercase ASCII letters to get the base codepoint.
pub const MAPVK_VK_TO_CHAR: UINT = 2;

/// Translate a virtual-key code to a character (unshifted) for the current
/// keyboard layout. Returns 0 if there is no translation.
pub extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) callconv(.winapi) UINT;

/// Copy the 256-byte virtual-key state array (the input to ToUnicodeEx). The
/// buffer must be 256 bytes.
pub extern "user32" fn GetKeyboardState(lpKeyState: [*]u8) callconv(.winapi) BOOL;

/// The active keyboard layout for the given thread (0 = the calling thread).
pub extern "user32" fn GetKeyboardLayout(idThread: DWORD) callconv(.winapi) HKL;

/// Translate a virtual key + scan code + key state into Unicode text using the
/// given keyboard layout. Returns:
///   >0  the number of UTF-16 units written to `pwszBuff`,
///    0  no translation,
///   -1  a dead key (the caller should treat the press as "composing" and call
///       again with the same arguments to avoid leaking the dead-key state).
pub extern "user32" fn ToUnicodeEx(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: [*]const u8,
    pwszBuff: [*]u16,
    cchBuff: INT,
    wFlags: UINT,
    dwhkl: ?HKL,
) callconv(.winapi) INT;

// --- gdi32 -----------------------------------------------------------------

pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) INT;
pub extern "gdi32" fn SetPixelFormat(hdc: HDC, format: INT, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

// --- opengl32 (WGL) --------------------------------------------------------

pub extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
pub extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// wglGetProcAddress, rejecting the non-null sentinels (1, 2, 3, -1) it returns
/// for unsupported entry points on some drivers (notably the GDI generic ICD).
/// Returns null for both the null and sentinel cases so callers can fall back.
pub fn wglProcChecked(name: [*:0]const u8) ?*const anyopaque {
    const p = wglGetProcAddress(name) orelse return null;
    const a = @intFromPtr(p);
    if (a <= 3 or a == std.math.maxInt(usize)) return null;
    return p;
}

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
