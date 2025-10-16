const Self = @This();

const std = @import("std");
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");
const Workspace = @import("Workspace.zig");

server: *Server,
xdg_toplevel: *wlr.XdgToplevel,
scene_tree: *wlr.SceneTree,
commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
map: wl.Listener(void) = .init(handleMap),
unmap: wl.Listener(void) = .init(handleUnmap),
destroy: wl.Listener(void) = .init(handleDestroy),
request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),

workspace_id: u8,
index: usize = 0,
scale: f64 = 0.0,

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

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const toplevel: *Self = @fieldParentPtr("commit", listener);
    if (toplevel.xdg_toplevel.base.initial_commit) {
        _ = toplevel.xdg_toplevel.setSize(0, 0);
    }
}

fn handleMap(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("map", listener);
    const server = self.server;

    _ = self.xdg_toplevel.setTiled(.{ .top = true, .bottom = true, .left = true, .right = true });

    self.index = self.server.toplevels.items.len;
    self.server.toplevels.append(gpa, self) catch {
        std.log.err("faied to append toplevel!", .{});
        return;
    };
    self.server.focusView(self);
    self.scene_tree.node.lowerToBottom();

    server.getActiveWorkspace().appendTile(self) catch |err| {
        std.log.err("failed to append toplevel! (err: {})", .{err});
    };
    server.applyWorkspaceLayout(self.workspace_id);
}

fn handleUnmap(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("unmap", listener);

    if (self == self.server.focused_toplevel) {
        self.server.focused_toplevel = null;
    }
    self.getWorkspace().removeTile(self);
    self.server.applyWorkspaceLayout(self.workspace_id);
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const self: *Self = @fieldParentPtr("destroy", listener);

    std.debug.assert(self != self.server.focused_toplevel);
    self.commit.link.remove();
    self.map.link.remove();
    self.unmap.link.remove();
    self.destroy.link.remove();
    self.request_move.link.remove();
    self.request_resize.link.remove();

    self.scene_tree.node.data = null;
    self.scene_tree.node.destroy();

    gpa.destroy(self);
}

fn handleRequestMove(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
    _: *wlr.XdgToplevel.event.Move,
) void {
    const self: *Self = @fieldParentPtr("request_move", listener);
    self.server.cursor_mode = .move;
}

fn handleRequestResize(
    listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
    event: *wlr.XdgToplevel.event.Resize,
) void {
    const self: *Self = @fieldParentPtr("request_resize", listener);

    if (event.serial == self.server.click_serial) {
        self.server.focusView(self);
        self.server.cursor_mode = .resize;
        self.server.resize_edges = event.edges;
    }
}
