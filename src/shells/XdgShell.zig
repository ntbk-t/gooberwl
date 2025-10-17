const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("../Server.zig");
const Toplevel = @import("Toplevel.zig");
const Popup = @import("Popup.zig");

xdg_shell: *wlr.XdgShell,
on_new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(onNewXdgToplevel),
on_new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(onNewXdgPopup),

pub fn init(wl_server: *wl.Server) !Self {
    return .{ .xdg_shell = try .create(wl_server, 2) };
}

pub fn deinit(self: *Self) void {
    self.on_new_xdg_toplevel.link.remove();
    self.on_new_xdg_popup.link.remove();
}

pub fn start(self: *Self) void {
    self.xdg_shell.events.new_toplevel.add(&self.on_new_xdg_toplevel);
    self.xdg_shell.events.new_popup.add(&self.on_new_xdg_popup);
}

pub fn getServer(self: *Self) *Server {
    return @fieldParentPtr("xdg_shell", self);
}

fn onNewXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    const self: *Self = @fieldParentPtr("on_new_xdg_toplevel", listener);

    Toplevel.create(self.getServer(), xdg_toplevel) catch {
        xdg_toplevel.sendClose();
    };
}

fn onNewXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
    Popup.create(xdg_popup) catch {
        xdg_popup.destroy();
    };
}
