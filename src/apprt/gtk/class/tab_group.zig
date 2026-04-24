//! Tab group data model for the GTK apprt.
//!
//! A `TabGroup` is a GObject that owns an ordered list of `Tab` widgets
//! plus display metadata (name, color, collapsed flag). It has no UI
//! by itself — the tab bar header and collapse/expand orchestration
//! live in `window.zig` and `tab_group_header.zig`.
//!
//! Ownership: the group holds strong references to its member tabs.
//! Callers closing a tab must `removeTab` it from its group before
//! (or as part of) unrefing it from the `AdwTabView`.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const Tab = @import("tab.zig").Tab;
const TabColor = @import("tab_color.zig").TabColor;
const Application = @import("application.zig").Application;

const log = std.log.scoped(.gtk_ghostty_tab_group);

pub const TabGroup = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabGroup",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// Stable numeric id, unique within the owning window. Assigned
        /// at construction and never changes.
        pub const id = struct {
            pub const name = "id";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        c_uint,
                        .{ .getter = Self.getIdCUint },
                    ),
                },
            );
        };

        /// Display name shown in the group header.
        pub const name_prop = struct {
            pub const name = "name";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("name"),
                },
            );
        };

        /// Palette color. Null or empty = `.none`. Mirrors `Tab.color`
        /// so downstream CSS/indicator code can treat them the same.
        pub const color = struct {
            pub const name = "color";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = Self.getColorName,
                            .setter = Self.setColorFromName,
                        },
                    ),
                },
            );
        };

        /// When true, non-active members are hidden (or rendered in
        /// peek mode if this group owns the active tab). Flipping this
        /// is the responsibility of `window.zig`'s collapse/expand
        /// orchestration; the property itself just stores the state
        /// and emits `notify::collapsed`.
        pub const collapsed = struct {
            pub const name = "collapsed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = Self.getCollapsed,
                            .setter = Self.setCollapsed,
                        },
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted after any add/remove changes the member list. The
        /// window listens to this to re-layout the tab strip.
        pub const @"member-changed" = struct {
            pub const name = "member-changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        id: c_uint = 0,
        name: ?[:0]const u8 = null,
        color: TabColor = .none,
        collapsed: bool = false,

        /// Ordered list of member tabs. The group holds a strong ref
        /// to each (ref taken on add, unref on remove / dispose).
        members: std.ArrayListUnmanaged(*Tab) = .empty,

        pub var offset: c_int = 0;
    };

    /// Create a new group with the given id, name, and color. The
    /// group is created empty; add tabs via `addTab`.
    pub fn new(
        id: c_uint,
        name_: ?[:0]const u8,
        color: TabColor,
    ) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.id = id;
        if (name_) |n| priv.name = glib.ext.dupeZ(u8, n);
        priv.color = color;
        return self;
    }

    //---------------------------------------------------------------
    // Properties

    pub fn getId(self: *Self) u32 {
        return @intCast(self.private().id);
    }

    /// Getter for the `id` property accessor (GObject-internal).
    pub fn getIdCUint(self: *Self) c_uint {
        return self.private().id;
    }

    pub fn getColor(self: *Self) TabColor {
        return self.private().color;
    }

    pub fn getColorName(self: *Self) ?[:0]const u8 {
        const c = self.private().color;
        return if (c == .none) null else c.name();
    }

    pub fn setColor(self: *Self, color: TabColor) void {
        const priv = self.private();
        if (priv.color == color) return;
        priv.color = color;
        self.as(gobject.Object).notifyByPspec(properties.color.impl.param_spec);
    }

    pub fn setColorFromName(self: *Self, color_name: ?[:0]const u8) void {
        const raw = color_name orelse {
            self.setColor(.none);
            return;
        };
        if (raw.len == 0) {
            self.setColor(.none);
            return;
        }
        const parsed = TabColor.fromString(raw) orelse {
            log.warn("ignoring unknown tab group color: {s}", .{raw});
            return;
        };
        self.setColor(parsed);
    }

    pub fn getCollapsed(self: *Self) bool {
        return self.private().collapsed;
    }

    pub fn setCollapsed(self: *Self, collapsed: bool) void {
        const priv = self.private();
        if (priv.collapsed == collapsed) return;
        priv.collapsed = collapsed;
        self.as(gobject.Object).notifyByPspec(properties.collapsed.impl.param_spec);
    }

    //---------------------------------------------------------------
    // Membership

    /// Add a tab to this group at the given position. The group takes
    /// a strong reference and sets the tab's back-reference to self.
    /// If `position` is `null`, the tab is appended.
    pub fn addTab(
        self: *Self,
        tab: *Tab,
        position: ?usize,
    ) Allocator.Error!void {
        const alloc = Application.default().allocator();
        const priv = self.private();

        const idx = position orelse priv.members.items.len;
        try priv.members.insert(alloc, idx, tab.ref());
        tab.setGroup(self);

        signals.@"member-changed".impl.emit(self, null, .{}, null);
    }

    /// Remove a tab from this group. Clears the tab's back-reference
    /// and drops the group's strong ref. Returns true if the tab was
    /// in the group, false otherwise.
    pub fn removeTab(self: *Self, tab: *Tab) bool {
        const priv = self.private();
        const idx = priv.indexOfTab(tab) orelse return false;

        const removed = priv.members.orderedRemove(idx);
        removed.setGroup(null);
        removed.unref();

        signals.@"member-changed".impl.emit(self, null, .{}, null);
        return true;
    }

    /// Return the member's position in the ordered list, or null if
    /// it isn't a member.
    pub fn indexOf(self: *Self, tab: *Tab) ?usize {
        return self.private().indexOfTab(tab);
    }

    pub fn isEmpty(self: *Self) bool {
        return self.private().members.items.len == 0;
    }

    pub fn memberCount(self: *Self) usize {
        return self.private().members.items.len;
    }

    /// Iterate members in order. The caller must not mutate the
    /// underlying list during iteration (no add/remove).
    pub fn members(self: *Self) []const *Tab {
        return self.private().members.items;
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // Members list starts `.empty`; nothing to do beyond whatever
        // `new` fills in.
        _ = self;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Drop our strong refs on every member. The members
        // themselves may still be referenced elsewhere (the
        // `AdwTabView`, a window) — we just release ours.
        for (priv.members.items) |tab| tab.unref();
        priv.members.clearRetainingCapacity();

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.name) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.name = null;
        }

        const alloc = Application.default().allocator();
        priv.members.deinit(alloc);

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Private helpers

    fn indexOfTab(priv: *Private, tab: *Tab) ?usize {
        for (priv.members.items, 0..) |m, i| {
            if (m == tab) return i;
        }
        return null;
    }

    //---------------------------------------------------------------
    // Common

    const Allocator = std.mem.Allocator;
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.id.impl,
                properties.name_prop.impl,
                properties.color.impl,
                properties.collapsed.impl,
            });

            signals.@"member-changed".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};

test "TabGroup get/set color" {
    // Basic enum plumbing — no instance creation (requires GType init).
    const testing = std.testing;
    try testing.expectEqual(@as(?TabColor, .blue), TabColor.fromString("blue"));
    try testing.expectEqual(@as(?TabColor, null), TabColor.fromString("unknown"));
}
