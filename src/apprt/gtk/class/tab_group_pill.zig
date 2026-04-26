//! Group header pill widget for the tab group bar.
//!
//! Displays a single `TabGroup`'s name and member count as a colored
//! pill. Subscribes to the group's `notify::name`, `notify::color`,
//! and `member-changed` signals so its appearance stays in sync
//! without the window needing to micromanage.
//!
//! Phase A: display only. Click-to-toggle-collapse and the header
//! context menu come in Phase B.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const gresource = @import("../build/gresource.zig");
const TabColor = @import("tab_color.zig").TabColor;
const TabGroup = @import("tab_group.zig").TabGroup;

const log = std.log.scoped(.gtk_ghostty_tab_group_pill);

pub const TabGroupPill = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabGroupPill",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// Weak reference to the group this pill represents. The
        /// window owns the group's strong ref; the pill is always
        /// shorter-lived than its group.
        group: ?*TabGroup = null,

        /// Signal handler ids so we can disconnect on destroy /
        /// group swap. Zero == not connected.
        notify_name_id: c_ulong = 0,
        notify_color_id: c_ulong = 0,
        member_changed_id: c_ulong = 0,

        // Template bindings.
        name_label: *gtk.Label,
        count_label: *gtk.Label,

        pub var offset: c_int = 0;
    };

    /// Create a new pill representing the given group.
    pub fn new(group: *TabGroup) *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Click gesture. The pill is a GtkBox, not a GtkButton,
        // because we want multi-child horizontal layout without
        // Button's single-child-with-internal-label convention.
        // GestureClick gives us press detection with the same
        // effective UX.
        const gesture = gtk.GestureClick.new();
        _ = gtk.GestureClick.signals.pressed.connect(
            gesture,
            *Self,
            onClick,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(gesture.as(gtk.EventController));

        // Cursor hint: pointer, so users discover it's clickable.
        self.as(gtk.Widget).setCursorFromName("pointer");

        self.setGroup(group);
        return self;
    }

    fn onClick(
        _: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const g = self.private().group orelse return;
        g.setCollapsed(!g.getCollapsed());
    }

    /// Which group this pill represents. The pill takes a strong ref
    /// on the group so the group can't be finalized while the pill
    /// is still alive (which would dangle the signal handlers
    /// connected in `connectGroup`). The ref is dropped in
    /// `disconnectGroup`.
    pub fn setGroup(self: *Self, group: *TabGroup) void {
        self.disconnectGroup();
        self.private().group = group.ref();
        self.connectGroup();
        self.refresh();
    }

    pub fn getGroup(self: *Self) ?*TabGroup {
        return self.private().group;
    }

    //---------------------------------------------------------------
    // Signal wiring

    fn connectGroup(self: *Self) void {
        const priv = self.private();
        const g = priv.group orelse return;

        priv.notify_name_id = gobject.Object.signals.notify.connect(
            g,
            *Self,
            onGroupPropertyChanged,
            self,
            .{ .detail = "name" },
        );
        priv.notify_color_id = gobject.Object.signals.notify.connect(
            g,
            *Self,
            onGroupPropertyChanged,
            self,
            .{ .detail = "color" },
        );
        priv.member_changed_id = TabGroup.signals.@"member-changed".connect(
            g,
            *Self,
            onGroupMemberChanged,
            self,
            .{},
        );
    }

    fn disconnectGroup(self: *Self) void {
        const priv = self.private();
        const g = priv.group orelse return;
        const obj = g.as(gobject.Object);

        if (priv.notify_name_id != 0) {
            gobject.signalHandlerDisconnect(obj, priv.notify_name_id);
            priv.notify_name_id = 0;
        }
        if (priv.notify_color_id != 0) {
            gobject.signalHandlerDisconnect(obj, priv.notify_color_id);
            priv.notify_color_id = 0;
        }
        if (priv.member_changed_id != 0) {
            gobject.signalHandlerDisconnect(obj, priv.member_changed_id);
            priv.member_changed_id = 0;
        }

        // Drop the strong ref taken in `setGroup`. After this the
        // group may finalize if no other ref-holder remains.
        g.unref();
        priv.group = null;
    }

    fn onGroupPropertyChanged(
        _: *TabGroup,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn onGroupMemberChanged(
        _: *TabGroup,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    /// Rebuild the pill's visible state from the group. Cheap: two
    /// label updates and a CSS class swap.
    fn refresh(self: *Self) void {
        const priv = self.private();
        const g = priv.group orelse return;

        if (g.getName()) |n| {
            priv.name_label.setLabel(n);
        } else {
            priv.name_label.setLabel("Group");
        }

        var count_buf: [16]u8 = undefined;
        const count_str = std.fmt.bufPrintZ(
            &count_buf,
            "{d}",
            .{g.memberCount()},
        ) catch "?";
        priv.count_label.setLabel(count_str);

        // Swap color class. Strip every possible class first so stale
        // ones don't stack.
        const widget = self.as(gtk.Widget);
        inline for (TabColor.all) |c| {
            if (c.pillCssClass()) |cls| widget.removeCssClass(cls);
        }
        if (g.getColor().pillCssClass()) |cls| widget.addCssClass(cls);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.disconnectGroup();
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Common

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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab-group-pill",
                }),
            );

            class.bindTemplateChildPrivate("name_label", .{});
            class.bindTemplateChildPrivate("count_label", .{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
