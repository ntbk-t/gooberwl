const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("Server.zig");

wlr_layer_shell: wlr.LayerShellV1,
on_new_surface: wl.Listener(*wlr.LayerSurfaceV1),

pub fn init(wl_server: *wl.Server) !Self {
    return .{ .wlr_layer_shell = try .create(wl_server, 1) };
}

pub fn deinit(self: *Self) void {
    self.on_new_surface.link.remove();
}

pub fn start(self: *Self) void {
    self.wlr_layer_shell.events.new_surface.add(&self.on_new_surface);
}

pub fn getServer(self: *Self) *Server {
    return @fieldParentPtr("xdg_shell", self);
}

fn onNewSurface(
    _: wl.Listener(*wlr.LayerSurfaceV1),
    _: *wlr.LayerSurfaceV1,
) void {}
