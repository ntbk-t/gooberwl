const Self = @This();

const std = @import("std");
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

xdg_popup: *wlr.XdgPopup,

on_commit: wl.Listener(*wlr.Surface) = .init(onCommit),
on_destroy: wl.Listener(void) = .init(onDestroy),

pub fn create(xdg_popup: *wlr.XdgPopup) !void {
    const xdg_surface = xdg_popup.base;

    // These asserts are fine since tinywl.zig doesn't support anything else that can
    // make xdg popups (e.g. layer shell).
    const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent orelse return error.NoParent) orelse return error.NoSurface;
    const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
        // The xdg surface user data could be left null due to allocation failure.
        return error.NoParentTree;
    };
    const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
        std.log.err("failed to allocate xdg popup node", .{});
        return;
    };
    xdg_surface.data = scene_tree;

    const popup = gpa.create(Self) catch {
        std.log.err("failed to allocate new popup", .{});
        return;
    };
    popup.* = .{
        .xdg_popup = xdg_popup,
    };

    xdg_surface.surface.events.commit.add(&popup.on_commit);
    xdg_popup.events.destroy.add(&popup.on_destroy);
}

fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const self: *Self = @fieldParentPtr("on_commit", listener);
    if (self.xdg_popup.base.initial_commit) {
        _ = self.xdg_popup.base.scheduleConfigure();
    }
}

fn onDestroy(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("on_destroy", listener);

    self.on_commit.link.remove();
    self.on_destroy.link.remove();

    gpa.destroy(self);
}
