//! whostty: minimal DirectWrite COM bindings for system-font discovery (#74).
//!
//! Hand-written vtable bindings — only the interfaces and methods the font
//! discovery path needs (factory -> font collection -> family -> font -> face
//! -> file -> local loader -> on-disk path). The method order in each `Vtbl`
//! mirrors `dwrite.h` exactly (a wrong slot order faults at run time, not at
//! compile time). Every COM method uses the Windows stdcall convention
//! (`callconv(.winapi)`); the first parameter is always `This`.
//!
//! Only compiled meaningfully on Windows; the externs link via zig's bundled
//! mingw `dwrite.def`. See PORTING.md and `font/discovery.zig`.
const std = @import("std");
const w = @import("windows.zig");

const HRESULT = w.HRESULT;
const BOOL = w.BOOL;

pub const UINT32 = u32;
pub const UINT16 = u16;
pub const ULONG = u32;
pub const WCHAR = u16;

/// COM GUID (== Win32 GUID / IID layout).
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

/// HRESULT success test (S_OK and any other non-negative code).
pub inline fn SUCCEEDED(hr: HRESULT) bool {
    return hr >= 0;
}

// --- Enums / constants -----------------------------------------------------

pub const DWRITE_FACTORY_TYPE_SHARED: i32 = 0;
pub const DWRITE_FACTORY_TYPE_ISOLATED: i32 = 1;

pub const DWRITE_FONT_STRETCH_NORMAL: i32 = 5;

// --- GUIDs -----------------------------------------------------------------

pub const IID_IDWriteFactory: GUID = .{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

pub const IID_IDWriteLocalFontFileLoader: GUID = .{
    .Data1 = 0xb2d9f3ec,
    .Data2 = 0xc9fe,
    .Data3 = 0x4a11,
    .Data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 },
};

// --- Entry point -----------------------------------------------------------

pub extern "dwrite" fn DWriteCreateFactory(
    factory_type: i32,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

// --- Interfaces ------------------------------------------------------------
//
// Each interface is an `extern struct` whose first field is `*const Vtbl`. The
// `Vtbl` lists every method as a `callconv(.winapi)` fn pointer in vtable order
// (IUnknown's QueryInterface/AddRef/Release first). Thin `pub fn` wrappers
// dispatch through the vtable for ergonomics.

pub const IDWriteFactory = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDWriteFactory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFactory) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFactory) callconv(.winapi) ULONG,
        // IDWriteFactory
        GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, BOOL) callconv(.winapi) HRESULT,
        CreateCustomFontCollection: *const fn (*IDWriteFactory, ?*anyopaque, ?*const anyopaque, UINT32, *?*anyopaque) callconv(.winapi) HRESULT,
        RegisterFontCollectionLoader: *const fn (*IDWriteFactory, ?*anyopaque) callconv(.winapi) HRESULT,
        UnregisterFontCollectionLoader: *const fn (*IDWriteFactory, ?*anyopaque) callconv(.winapi) HRESULT,
        CreateFontFileReference: *const fn (*IDWriteFactory, [*:0]const WCHAR, ?*const FILETIME, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateCustomFontFileReference: *const fn (*IDWriteFactory, ?*const anyopaque, UINT32, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateFontFace: *const fn (*IDWriteFactory, i32, UINT32, [*]const ?*anyopaque, UINT32, i32, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateRenderingParams: *const fn (*IDWriteFactory, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateMonitorRenderingParams: *const fn (*IDWriteFactory, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateCustomRenderingParams: *const fn (*IDWriteFactory, f32, f32, f32, i32, i32, *?*anyopaque) callconv(.winapi) HRESULT,
        RegisterFontFileLoader: *const fn (*IDWriteFactory, ?*anyopaque) callconv(.winapi) HRESULT,
        UnregisterFontFileLoader: *const fn (*IDWriteFactory, ?*anyopaque) callconv(.winapi) HRESULT,
        CreateTextFormat: *const fn (*IDWriteFactory, [*:0]const WCHAR, ?*anyopaque, i32, i32, i32, f32, [*:0]const WCHAR, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateTypography: *const fn (*IDWriteFactory, *?*anyopaque) callconv(.winapi) HRESULT,
        GetGdiInterop: *const fn (*IDWriteFactory, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateTextLayout: *const fn (*IDWriteFactory, [*]const WCHAR, UINT32, ?*anyopaque, f32, f32, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateGdiCompatibleTextLayout: *const fn (*IDWriteFactory, [*]const WCHAR, UINT32, ?*anyopaque, f32, f32, f32, ?*const anyopaque, BOOL, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateEllipsisTrimmingSign: *const fn (*IDWriteFactory, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateTextAnalyzer: *const fn (*IDWriteFactory, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateNumberSubstitution: *const fn (*IDWriteFactory, i32, [*:0]const WCHAR, BOOL, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateGlyphRunAnalysis: *const fn (*IDWriteFactory, ?*const anyopaque, f32, ?*const anyopaque, i32, i32, f32, f32, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFactory) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn GetSystemFontCollection(self: *IDWriteFactory, collection: *?*IDWriteFontCollection, check_for_updates: BOOL) HRESULT {
        return self.vtbl.GetSystemFontCollection(self, collection, check_for_updates);
    }
};

pub const IDWriteFontCollection = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteFontCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontCollection) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFontCollection) callconv(.winapi) ULONG,
        GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.winapi) UINT32,
        GetFontFamily: *const fn (*IDWriteFontCollection, UINT32, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        FindFamilyName: *const fn (*IDWriteFontCollection, [*:0]const WCHAR, *UINT32, *BOOL) callconv(.winapi) HRESULT,
        GetFontFromFontFace: *const fn (*IDWriteFontCollection, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontCollection) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn GetFontFamilyCount(self: *IDWriteFontCollection) UINT32 {
        return self.vtbl.GetFontFamilyCount(self);
    }
    pub inline fn GetFontFamily(self: *IDWriteFontCollection, index: UINT32, family: *?*IDWriteFontFamily) HRESULT {
        return self.vtbl.GetFontFamily(self, index, family);
    }
    pub inline fn FindFamilyName(self: *IDWriteFontCollection, name: [*:0]const WCHAR, index: *UINT32, exists: *BOOL) HRESULT {
        return self.vtbl.FindFamilyName(self, name, index, exists);
    }
};

pub const IDWriteFontFamily = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontFamily) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFontFamily) callconv(.winapi) ULONG,
        // IDWriteFontList
        GetFontCollection: *const fn (*IDWriteFontFamily, *?*anyopaque) callconv(.winapi) HRESULT,
        GetFontCount: *const fn (*IDWriteFontFamily) callconv(.winapi) UINT32,
        GetFont: *const fn (*IDWriteFontFamily, UINT32, *?*IDWriteFont) callconv(.winapi) HRESULT,
        // IDWriteFontFamily
        GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        GetFirstMatchingFont: *const fn (*IDWriteFontFamily, i32, i32, i32, *?*IDWriteFont) callconv(.winapi) HRESULT,
        GetMatchingFonts: *const fn (*IDWriteFontFamily, i32, i32, i32, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontFamily) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn GetFamilyNames(self: *IDWriteFontFamily, names: *?*IDWriteLocalizedStrings) HRESULT {
        return self.vtbl.GetFamilyNames(self, names);
    }
    /// Note: param order is weight, stretch, style (stretch in the middle).
    pub inline fn GetFirstMatchingFont(self: *IDWriteFontFamily, weight: i32, stretch: i32, style: i32, font: *?*IDWriteFont) HRESULT {
        return self.vtbl.GetFirstMatchingFont(self, weight, stretch, style, font);
    }
};

pub const IDWriteFont = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteFont, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFont) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFont) callconv(.winapi) ULONG,
        GetFontFamily: *const fn (*IDWriteFont, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
        GetWeight: *const fn (*IDWriteFont) callconv(.winapi) i32,
        GetStretch: *const fn (*IDWriteFont) callconv(.winapi) i32,
        GetStyle: *const fn (*IDWriteFont) callconv(.winapi) i32,
        IsSymbolFont: *const fn (*IDWriteFont) callconv(.winapi) BOOL,
        GetFaceNames: *const fn (*IDWriteFont, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
        GetInformationalStrings: *const fn (*IDWriteFont, i32, *?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
        GetSimulations: *const fn (*IDWriteFont) callconv(.winapi) i32,
        GetMetrics: *const fn (*IDWriteFont, ?*anyopaque) callconv(.winapi) void,
        HasCharacter: *const fn (*IDWriteFont, UINT32, *BOOL) callconv(.winapi) HRESULT,
        CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFont) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn CreateFontFace(self: *IDWriteFont, face: *?*IDWriteFontFace) HRESULT {
        return self.vtbl.CreateFontFace(self, face);
    }
};

pub const IDWriteFontFace = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteFontFace, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontFace) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFontFace) callconv(.winapi) ULONG,
        GetType: *const fn (*IDWriteFontFace) callconv(.winapi) i32,
        GetFiles: *const fn (*IDWriteFontFace, *UINT32, ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
        GetIndex: *const fn (*IDWriteFontFace) callconv(.winapi) UINT32,
        GetSimulations: *const fn (*IDWriteFontFace) callconv(.winapi) i32,
        IsSymbolFont: *const fn (*IDWriteFontFace) callconv(.winapi) BOOL,
        GetMetrics: *const fn (*IDWriteFontFace, ?*anyopaque) callconv(.winapi) void,
        GetGlyphCount: *const fn (*IDWriteFontFace) callconv(.winapi) UINT16,
        GetDesignGlyphMetrics: *const fn (*IDWriteFontFace, ?*const UINT16, UINT32, ?*anyopaque, BOOL) callconv(.winapi) HRESULT,
        GetGlyphIndices: *const fn (*IDWriteFontFace, ?*const UINT32, UINT32, ?*UINT16) callconv(.winapi) HRESULT,
        TryGetFontTable: *const fn (*IDWriteFontFace, UINT32, *?*const anyopaque, *UINT32, *?*anyopaque, *BOOL) callconv(.winapi) HRESULT,
        ReleaseFontTable: *const fn (*IDWriteFontFace, ?*anyopaque) callconv(.winapi) void,
        GetGlyphRunOutline: *const fn (*IDWriteFontFace, f32, ?*const UINT16, ?*const f32, ?*const anyopaque, UINT32, BOOL, BOOL, ?*anyopaque) callconv(.winapi) HRESULT,
        GetRecommendedRenderingMode: *const fn (*IDWriteFontFace, f32, f32, i32, ?*anyopaque, *i32) callconv(.winapi) HRESULT,
        GetGdiCompatibleMetrics: *const fn (*IDWriteFontFace, f32, f32, ?*const anyopaque, ?*anyopaque) callconv(.winapi) HRESULT,
        GetGdiCompatibleGlyphMetrics: *const fn (*IDWriteFontFace, f32, f32, ?*const anyopaque, BOOL, ?*const UINT16, UINT32, ?*anyopaque, BOOL) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontFace) ULONG {
        return self.vtbl.Release(self);
    }
    /// `number_of_files` is in/out: call once with `fontfiles == null` to query
    /// the count, then again with a sized buffer.
    pub inline fn GetFiles(self: *IDWriteFontFace, number_of_files: *UINT32, fontfiles: ?[*]?*IDWriteFontFile) HRESULT {
        return self.vtbl.GetFiles(self, number_of_files, fontfiles);
    }
    pub inline fn GetIndex(self: *IDWriteFontFace) UINT32 {
        return self.vtbl.GetIndex(self);
    }
};

pub const IDWriteFontFile = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteFontFile, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontFile) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFontFile) callconv(.winapi) ULONG,
        GetReferenceKey: *const fn (*IDWriteFontFile, *?*const anyopaque, *UINT32) callconv(.winapi) HRESULT,
        GetLoader: *const fn (*IDWriteFontFile, *?*IDWriteFontFileLoader) callconv(.winapi) HRESULT,
        Analyze: *const fn (*IDWriteFontFile, *BOOL, *i32, *i32, *UINT32) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontFile) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn GetReferenceKey(self: *IDWriteFontFile, key: *?*const anyopaque, key_size: *UINT32) HRESULT {
        return self.vtbl.GetReferenceKey(self, key, key_size);
    }
    pub inline fn GetLoader(self: *IDWriteFontFile, loader: *?*IDWriteFontFileLoader) HRESULT {
        return self.vtbl.GetLoader(self, loader);
    }
};

pub const IDWriteFontFileLoader = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteFontFileLoader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteFontFileLoader) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteFontFileLoader) callconv(.winapi) ULONG,
        CreateStreamFromKey: *const fn (*IDWriteFontFileLoader, ?*const anyopaque, UINT32, *?*anyopaque) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteFontFileLoader) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn QueryInterface(self: *IDWriteFontFileLoader, iid: *const GUID, out: *?*anyopaque) HRESULT {
        return self.vtbl.QueryInterface(self, iid, out);
    }
};

pub const IDWriteLocalFontFileLoader = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteLocalFontFileLoader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) ULONG,
        // IDWriteFontFileLoader
        CreateStreamFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, UINT32, *?*anyopaque) callconv(.winapi) HRESULT,
        // IDWriteLocalFontFileLoader
        GetFilePathLengthFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, UINT32, *UINT32) callconv(.winapi) HRESULT,
        GetFilePathFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, UINT32, [*]WCHAR, UINT32) callconv(.winapi) HRESULT,
        GetLastWriteTimeFromKey: *const fn (*IDWriteLocalFontFileLoader, ?*const anyopaque, UINT32, *FILETIME) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteLocalFontFileLoader) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn GetFilePathLengthFromKey(self: *IDWriteLocalFontFileLoader, key: ?*const anyopaque, key_size: UINT32, length: *UINT32) HRESULT {
        return self.vtbl.GetFilePathLengthFromKey(self, key, key_size, length);
    }
    pub inline fn GetFilePathFromKey(self: *IDWriteLocalFontFileLoader, key: ?*const anyopaque, key_size: UINT32, path: [*]WCHAR, length: UINT32) HRESULT {
        return self.vtbl.GetFilePathFromKey(self, key, key_size, path, length);
    }
};

/// Used to read enumerated family names. We only need the first string's length
/// and value (locale-0).
pub const IDWriteLocalizedStrings = extern struct {
    vtbl: *const Vtbl,

    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IDWriteLocalizedStrings, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) ULONG,
        Release: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) ULONG,
        GetCount: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) UINT32,
        FindLocaleName: *const fn (*IDWriteLocalizedStrings, [*:0]const WCHAR, *UINT32, *BOOL) callconv(.winapi) HRESULT,
        GetLocaleNameLength: *const fn (*IDWriteLocalizedStrings, UINT32, *UINT32) callconv(.winapi) HRESULT,
        GetLocaleName: *const fn (*IDWriteLocalizedStrings, UINT32, [*]WCHAR, UINT32) callconv(.winapi) HRESULT,
        GetStringLength: *const fn (*IDWriteLocalizedStrings, UINT32, *UINT32) callconv(.winapi) HRESULT,
        GetString: *const fn (*IDWriteLocalizedStrings, UINT32, [*]WCHAR, UINT32) callconv(.winapi) HRESULT,
    };

    pub inline fn Release(self: *IDWriteLocalizedStrings) ULONG {
        return self.vtbl.Release(self);
    }
    pub inline fn GetStringLength(self: *IDWriteLocalizedStrings, index: UINT32, length: *UINT32) HRESULT {
        return self.vtbl.GetStringLength(self, index, length);
    }
    pub inline fn GetString(self: *IDWriteLocalizedStrings, index: UINT32, buffer: [*]WCHAR, size: UINT32) HRESULT {
        return self.vtbl.GetString(self, index, buffer, size);
    }
};
