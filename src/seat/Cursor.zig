const Self = @This();

const std = @import("std");
const log = std.log;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Seat = @import("Seat.zig");
const Server = @import("../Server.zig");

wlr_cursor: *wlr.Cursor,
attached_devices: usize = 0,
mode: enum { passthrough, move, resize } = .passthrough,
resize_edges: wlr.Edges = .{},
click_serial: u32 = 0,

on_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(onMotion),
on_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(onMotionAbsolute),
on_button: wl.Listener(*wlr.Pointer.event.Button) = .init(onButton),
on_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(onAxis),
on_frame: wl.Listener(*wlr.Cursor) = .init(onFrame),

pub fn init() !Self {
    return .{ .wlr_cursor = try wlr.Cursor.create() };
}

pub fn start(self: *Self) void {
    self.wlr_cursor.events.motion.add(&self.on_motion);
    self.wlr_cursor.events.motion_absolute.add(&self.on_motion_absolute);
    self.wlr_cursor.events.button.add(&self.on_button);
    self.wlr_cursor.events.axis.add(&self.on_axis);
    self.wlr_cursor.events.frame.add(&self.on_frame);
}

pub fn deinit(self: *Self) void {
    self.on_motion.link.remove();
    self.on_motion_absolute.link.remove();
    self.on_button.link.remove();
    self.on_axis.link.remove();
    self.on_frame.link.remove();
}

pub fn getSeat(self: *Self) *Seat {
    return @fieldParentPtr("cursor", self);
}

pub fn addInput(self: *Self, device: *wlr.InputDevice) void {
    self.wlr_cursor.attachInputDevice(device);
}

fn onMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const self: *Self = @fieldParentPtr("on_motion", listener);
    self.wlr_cursor.move(event.device, event.delta_x, event.delta_y);
    self.processMotion(event.time_msec);
}

fn onMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const self: *Self = @fieldParentPtr("on_motion_absolute", listener);
    self.wlr_cursor.warpAbsolute(event.device, event.x, event.y);
    self.processMotion(event.time_msec);
}

fn onButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const self: *Self = @fieldParentPtr("on_button", listener);
    const seat = self.getSeat();
    const server = seat.getServer();

    const serial = seat.pointerNotifyButton(event);
    switch (event.state) {
        .pressed => {
            self.click_serial = serial;
            if (server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |res| {
                server.focusView(res.toplevel);
            }
        },
        .released => {
            switch (self.mode) {
                .passthrough => {},
                .move => self.processMove(),
                .resize => self.mode = .passthrough,
            }
            self.mode = .passthrough;
        },
        _ => {},
    }
}

fn onAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const self: *Self = @fieldParentPtr("on_axis", listener);
    self.getSeat().pointerNotifyAxis(event);
}

fn onFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const self: *Self = @fieldParentPtr("on_frame", listener);
    self.getSeat().pointerNotifyFrame();
}

fn processMotion(self: *Self, time_msec: u32) void {
    switch (self.mode) {
        .passthrough => self.processPassthrough(time_msec),
        .resize => self.processResize(),
        .move => {},
    }
}

fn processMove(self: *Self) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    const focused = seat.focused_toplevel orelse return;
    const view_at = server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;

    focused.getWorkspace().swapTiles(focused, view_at.toplevel);
}

fn processPassthrough(self: *Self, time_msec: u32) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    if (server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |res| {
        seat.pointerNotifyEnter(res.surface, res.sx, res.sy, time_msec);
    } else {
        self.wlr_cursor.setXcursor(server.cursor_mgr, "default");
        seat.pointerNotifyExit();
    }
}

fn processResize(self: *Self) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    const toplevel = seat.focused_toplevel orelse {
        std.log.warn("cursor mode set to resize, but no toplevel is focused!", .{});
        self.mode = .passthrough;
        return;
    };

    const output = server.output_layout.outputAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;
    var layout_dirty = false;

    if ((toplevel.index != 0 and self.resize_edges.left) or
        (toplevel.index == 0 and self.resize_edges.right))
    {
        toplevel.getWorkspace().horizontal_ratio = self.wlr_cursor.x / @as(f64, @floatFromInt(output.width));
        layout_dirty = true;
    }

    if (toplevel.index > 1 and self.resize_edges.top) {
        const prev = toplevel.getWorkspace().toplevels.items[toplevel.index - 1];
        prev.getWorkspace().resizeTile(prev, self.wlr_cursor.y);
        layout_dirty = true;
    }

    if (toplevel.index != 0 and
        toplevel.index != toplevel.getWorkspace().toplevels.items.len - 1 and
        self.resize_edges.bottom)
    {
        toplevel.getWorkspace().resizeTile(toplevel, self.wlr_cursor.y);
        layout_dirty = true;
    }

    if (layout_dirty == true) {
        server.applyWorkspaceLayout(toplevel.workspace_id);
    }
}
