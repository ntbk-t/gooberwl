const Self = @This();

const std = @import("std");
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Workspace = @import("../Workspace.zig");

server: *Server,
xdg_toplevel: *wlr.XdgToplevel,
scene_tree: *wlr.SceneTree,
on_commit: wl.Listener(*wlr.Surface) = .init(onCommit),
on_map: wl.Listener(void) = .init(onMap),
on_unmap: wl.Listener(void) = .init(onUnmap),
on_destroy: wl.Listener(void) = .init(onDestroy),
on_request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(onRequestMove),
on_request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(onRequestResize),

workspace_id: u8,
index: usize = 0,
scale: f64 = 0.0,

pub fn create(server: *Server, xdg_toplevel: *wlr.XdgToplevel) !void {
    const xdg_surface = xdg_toplevel.base;

    // Don't add the toplevel to self.toplevels until it is mapped
    const toplevel = gpa.create(Self) catch |err| {
        std.log.err("failed to allocate space for toplevel!", .{});
        return err;
    };
    errdefer gpa.destroy(toplevel);

    toplevel.* = .{
        .server = server,
        .xdg_toplevel = xdg_toplevel,
        .scene_tree = server.scene.tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to create scene tree node for toplevel!", .{});
            return error.CreateSceneXdgSurface;
        },
        .workspace_id = server.active_workspace,
    };
    toplevel.scene_tree.node.data = toplevel;
    xdg_surface.data = toplevel.scene_tree;

    xdg_surface.surface.events.commit.add(&toplevel.on_commit);
    xdg_surface.surface.events.map.add(&toplevel.on_map);
    xdg_surface.surface.events.unmap.add(&toplevel.on_unmap);
    xdg_toplevel.events.destroy.add(&toplevel.on_destroy);
    xdg_toplevel.events.request_move.add(&toplevel.on_request_move);
    xdg_toplevel.events.request_resize.add(&toplevel.on_request_resize);
}

pub fn getRect(self: *Self) struct { x: f64, y: f64, width: f64, height: f64 } {
    const workspace = self.getWorkspace();
    return .{
        .x = @floatFromInt(self.scene_tree.node.x),
        .y = @floatFromInt(self.scene_tree.node.y),
        .width = @as(f64, @floatFromInt(workspace.width)) * if (self.index == 0)
            workspace.horizontal_ratio
        else
            (1 - workspace.horizontal_ratio),
        .height = @as(
            f64,
            @floatFromInt(workspace.height),
        ) * self.scale / workspace.total_scale,
    };
}

pub fn getWorkspace(self: *Self) *Workspace {
    return self.server.getWorkspace(self.workspace_id);
}

pub fn setSize(self: *Self, width: i32, height: i32) void {
    if (width < 0 or height < 0) {
        @branchHint(.cold);
        std.log.warn("tried to set window to negative size!", .{});
        _ = self.xdg_toplevel.setSize(0, 0);
        return;
    }

    _ = self.xdg_toplevel.setSize(width, height);
}

pub fn setRect(self: *Self, x: i32, y: i32, width: i32, height: i32) void {
    self.scene_tree.node.setPosition(x, y);
    self.setSize(width, height);
}

fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *Self = @fieldParentPtr("on_commit", listener);
    if (toplevel.xdg_toplevel.base.initial_commit) {
        _ = toplevel.xdg_toplevel.setSize(0, 0);
    }
}

fn onMap(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("on_map", listener);
    const server = self.server;

    _ = self.xdg_toplevel.setTiled(
        .{ .top = true, .bottom = true, .left = true, .right = true },
    );

    self.server.focusView(self);
    self.scene_tree.node.lowerToBottom();

    server.getActiveWorkspace().appendTile(self) catch |err| {
        std.log.err("failed to append toplevel! (err: {})", .{err});
    };
    server.applyWorkspaceLayout(self.workspace_id);
}

fn onUnmap(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("on_unmap", listener);

    if (self == self.server.seat.focused_toplevel) {
        self.server.seat.focused_toplevel = null;
    }
    self.getWorkspace().removeTile(self);
    self.server.applyWorkspaceLayout(self.workspace_id);
}

fn onDestroy(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("on_destroy", listener);

    std.debug.assert(self != self.server.seat.focused_toplevel);
    self.on_commit.link.remove();
    self.on_map.link.remove();
    self.on_unmap.link.remove();
    self.on_destroy.link.remove();
    self.on_request_move.link.remove();
    self.on_request_resize.link.remove();

    self.scene_tree.node.data = null;
    self.scene_tree.node.destroy();

    gpa.destroy(self);
}

fn onRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    event: *wlr.XdgToplevel.event.Move,
) void {
    const self: *Self = @fieldParentPtr("on_request_move", listener);

    if (event.serial == self.server.seat.cursor.click_serial) {
        self.server.seat.cursor.startMove(self);
    }
}

fn onRequestResize(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
    event: *wlr.XdgToplevel.event.Resize,
) void {
    const self: *Self = @fieldParentPtr("on_request_resize", listener);

    self.server.seat.cursor.startResize(self, event.edges);
}
