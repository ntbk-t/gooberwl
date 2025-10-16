const Self = @This();

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Cursor = @import("Cursor.zig");
const Server = @import("../Server.zig");

wlr_seat: *wlr.Seat,
cursor: Cursor,

pub fn getServer(self: *Self) *Server {
    return @fieldParentPtr("seat", self);
}
