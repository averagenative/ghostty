//! Tab color palette for the GTK apprt.
//!
//! A small fixed palette for per-tab color tagging, plus helpers used
//! when rendering the tab-strip indicator and applying CSS classes.

const std = @import("std");

pub const TabColor = enum(u8) {
    none = 0,
    blue,
    teal,
    green,
    yellow,
    orange,
    red,
    pink,
    purple,
    slate,

    pub const all = [_]TabColor{
        .none, .blue, .teal, .green, .yellow,
        .orange, .red, .pink, .purple, .slate,
    };

    pub fn fromString(s: []const u8) ?TabColor {
        const fields = @typeInfo(TabColor).@"enum".fields;
        inline for (fields) |f| {
            if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
        }
        return null;
    }

    pub fn name(self: TabColor) [:0]const u8 {
        return switch (self) {
            .none => "none",
            .blue => "blue",
            .teal => "teal",
            .green => "green",
            .yellow => "yellow",
            .orange => "orange",
            .red => "red",
            .pink => "pink",
            .purple => "purple",
            .slate => "slate",
        };
    }

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    /// 8-bit RGB triple for the palette entry. For `.none` returns
    /// all zeros (callers should not reach this for `.none`).
    pub fn rgb(self: TabColor) Rgb {
        const h = self.hex();
        if (h.len != 6) return .{ .r = 0, .g = 0, .b = 0 };
        return .{
            .r = (digit(h[0]) << 4) | digit(h[1]),
            .g = (digit(h[2]) << 4) | digit(h[3]),
            .b = (digit(h[4]) << 4) | digit(h[5]),
        };
    }

    fn digit(c: u8) u8 {
        return std.fmt.charToDigit(c, 16) catch 0;
    }

    /// Hex RGB for the palette entry (no leading `#`). Returns empty for `.none`.
    pub fn hex(self: TabColor) [:0]const u8 {
        return switch (self) {
            .none => "",
            .blue => "3584e4",
            .teal => "33b1b1",
            .green => "26a269",
            .yellow => "cd9309",
            .orange => "ed5b00",
            .red => "e01b24",
            .pink => "c061cb",
            .purple => "9141ac",
            .slate => "5e5c64",
        };
    }

    /// CSS class name applied to the tab widget for this color.
    /// Returns null for `.none` so callers skip applying a class.
    pub fn cssClass(self: TabColor) ?[:0]const u8 {
        return switch (self) {
            .none => null,
            .blue => "tab-color-blue",
            .teal => "tab-color-teal",
            .green => "tab-color-green",
            .yellow => "tab-color-yellow",
            .orange => "tab-color-orange",
            .red => "tab-color-red",
            .pink => "tab-color-pink",
            .purple => "tab-color-purple",
            .slate => "tab-color-slate",
        };
    }

    /// CSS class applied directly to each rendered `AdwTab` widget in
    /// the tab bar for this color. Distinct from `cssClass` so we
    /// don't collide with any libadwaita-internal `.tab-*` classes.
    /// Null for `.none`.
    pub fn barCssClass(self: TabColor) ?[:0]const u8 {
        return switch (self) {
            .none => null,
            .blue => "gh-tab-color-blue",
            .teal => "gh-tab-color-teal",
            .green => "gh-tab-color-green",
            .yellow => "gh-tab-color-yellow",
            .orange => "gh-tab-color-orange",
            .red => "gh-tab-color-red",
            .pink => "gh-tab-color-pink",
            .purple => "gh-tab-color-purple",
            .slate => "gh-tab-color-slate",
        };
    }

    /// Localized human-readable label for menu entries.
    pub fn label(self: TabColor) [:0]const u8 {
        return switch (self) {
            .none => "None",
            .blue => "Blue",
            .teal => "Teal",
            .green => "Green",
            .yellow => "Yellow",
            .orange => "Orange",
            .red => "Red",
            .pink => "Pink",
            .purple => "Purple",
            .slate => "Slate",
        };
    }
};

test "fromString round-trips every variant" {
    inline for (@typeInfo(TabColor).@"enum".fields) |f| {
        const parsed = TabColor.fromString(f.name);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(@as(TabColor, @enumFromInt(f.value)), parsed.?);
    }
}

test "fromString rejects unknown and empty" {
    try std.testing.expect(TabColor.fromString("") == null);
    try std.testing.expect(TabColor.fromString("chartreuse") == null);
    try std.testing.expect(TabColor.fromString("BLUE") == null);
}

test "cssClass is null only for none" {
    try std.testing.expect(TabColor.cssClass(.none) == null);
    for (TabColor.all) |c| {
        if (c == .none) continue;
        try std.testing.expect(TabColor.cssClass(c) != null);
    }
}
