const Self = @This();

const std = @import("std");
const log = std.log;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Cursor = @import("Cursor.zig");
const Server = @import("../Server.zig");
const Keyboard = @import("Keyboard.zig");
const Toplevel = @import("../xdg_shell/Toplevel.zig");

wlr_seat: *wlr.Seat,
on_request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
on_request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),

focused_toplevel: ?*Toplevel = null,
keyboards: usize = 0,

cursor: Cursor,

pub fn init(server: *wl.Server, name: [*:0]const u8) !Self {
    return .{
        .wlr_seat = try wlr.Seat.create(server, name),
        .cursor = try .init(),
    };
}

pub fn deinit(self: *Self) void {
    self.on_request_set_cursor.link.remove();
    self.on_request_set_selection.link.remove();
    self.cursor.deinit();
}

pub fn start(self: *Self) void {
    self.wlr_seat.events.request_set_cursor.add(&self.on_request_set_cursor);
    self.wlr_seat.events.request_set_selection.add(&self.on_request_set_selection);
    self.cursor.start();
}

pub fn getServer(self: *Self) *Server {
    return @fieldParentPtr("seat", self);
}

pub fn addInput(self: *Self, device: *wlr.InputDevice) void {
    switch (device.type) {
        .keyboard => Keyboard.create(self, device.toKeyboard()) catch |err| {
            log.err("failed to create keyboard: {}", .{err});
            return;
        },
        .pointer => {
            self.cursor.addInput(device);
        },
        else => {},
    }

    self.wlr_seat.setCapabilities(.{
        .pointer = true,
        .keyboard = self.keyboards > 0,
    });
}

pub fn keyboardNotifyModifiers(self: Self, wlr_keyboard: *wlr.Keyboard) void {
    self.wlr_seat.setKeyboard(wlr_keyboard);
    self.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
}

pub fn keyboardNotifyKey(self: Self, wlr_keyboard: *wlr.Keyboard, event: *const wlr.Keyboard.event.Key) void {
    self.wlr_seat.setKeyboard(wlr_keyboard);
    self.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
}

pub fn pointerNotifyFrame(self: Self) void {
    self.wlr_seat.pointerNotifyFrame();
}
pub fn pointerNotifyButton(self: Self, event: *const wlr.Pointer.event.Button) u32 {
    return self.wlr_seat.pointerNotifyButton(event.time_msec, event.button, event.state);
}
pub fn pointerNotifyAxis(self: Self, event: *const wlr.Pointer.event.Axis) void {
    return self.wlr_seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}
pub fn pointerNotifyEnter(self: Self, surface: *wlr.Surface, x: f64, y: f64, time_msec: u32) void {
    self.wlr_seat.pointerNotifyEnter(surface, x, y);
    self.wlr_seat.pointerNotifyMotion(time_msec, x, y);
}
pub fn pointerNotifyExit(self: Self) void {
    self.wlr_seat.pointerClearFocus();
}

fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const self: *Self = @fieldParentPtr("on_request_set_cursor", listener);

    if (event.seat_client == self.wlr_seat.pointer_state.focused_client)
        self.cursor.wlr_cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const self: *Self = @fieldParentPtr("on_request_set_selection", listener);
    self.wlr_seat.setSelection(event.source, event.serial);
}
