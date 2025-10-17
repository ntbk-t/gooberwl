const Self = @This();

const std = @import("std");
const log = std.log;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Seat = @import("Seat.zig");
const Server = @import("../Server.zig");
const Toplevel = @import("../shells/Toplevel.zig");

const State = union(enum) {
    passthrough: void,
    move: struct {
        toplevel: *Toplevel,
        x_offset: f64,
        y_offset: f64,
    },
    resize: struct {
        toplevel: *Toplevel,
        edges: wlr.Edges,
        x_offset: f64,
        y_offset: f64,
    },
};

wlr_cursor: *wlr.Cursor,
attached_devices: usize = 0,
state: State = .{ .passthrough = {} },
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

    switch (event.state) {
        .pressed => {
            if (seat.wlr_seat.getKeyboard()) |keyboard| {
                if (keyboard.getModifiers().alt) {
                    server.handleMousebind(event.button, self.wlr_cursor.x, self.wlr_cursor.y);
                    return;
                }
            }
            self.click_serial = seat.pointerNotifyButton(event);
            if (server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |res| {
                server.focusView(res.toplevel);
            }
        },
        .released => {
            switch (self.state) {
                .passthrough => {},
                .move => self.endMove(event.time_msec),
                .resize => seat.pointerNotifyExit(),
            }
            self.state = .{ .passthrough = {} };
            _ = seat.pointerNotifyButton(event);
        },
        _ => _ = seat.pointerNotifyButton(event),
    }
}

fn onAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const self: *Self = @fieldParentPtr("on_axis", listener);
    const seat = self.getSeat();
    const server = seat.getServer();

    if (seat.wlr_seat.getKeyboard()) |keyboard| {
        if (keyboard.getModifiers().alt) {
            server.getActiveWorkspace().scroll += event.delta;
            server.getActiveWorkspace().applyLayout();
            return;
        }
    }

    self.getSeat().pointerNotifyAxis(event);
}

fn onFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const self: *Self = @fieldParentPtr("on_frame", listener);
    self.getSeat().pointerNotifyFrame();
}

fn processMotion(self: *Self, time_msec: u32) void {
    switch (self.state) {
        .passthrough => self.updatePassthrough(time_msec),
        .move => {},
        .resize => |resize| self.updateResize(resize.toplevel, resize.x_offset, resize.y_offset, resize.edges),
    }
}

pub fn startMove(self: *Self, toplevel: *Toplevel) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    seat.pointerNotifyExit();
    self.wlr_cursor.setXcursor(server.cursor_mgr, "hand1");

    self.state = .{
        .move = .{
            .toplevel = toplevel,
            .x_offset = self.wlr_cursor.x - @as(f64, @floatFromInt(toplevel.scene_tree.node.x)),
            .y_offset = self.wlr_cursor.y - @as(f64, @floatFromInt(toplevel.scene_tree.node.y)),
        },
    };
}

pub fn startResize(self: *Self, toplevel: *Toplevel, edges: wlr.Edges) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    if (edges.left or edges.right) {
        if (edges.top or edges.bottom) {
            self.wlr_cursor.setXcursor(server.cursor_mgr, "all-scroll");
        } else {
            self.wlr_cursor.setXcursor(server.cursor_mgr, "col-resize");
        }
    } else if (edges.top or edges.bottom) {
        self.wlr_cursor.setXcursor(server.cursor_mgr, "hand1");
    } else {
        return;
    }
    seat.pointerNotifyExit();

    const rect = toplevel.getRect();

    // OH GOD D:
    const edge_x =
        if (edges.left)
            rect.x
        else if (edges.right)
            rect.x + rect.width
        else
            self.wlr_cursor.x;

    const edge_y =
        if (edges.top)
            rect.y
        else if (edges.bottom)
            rect.y + rect.height
        else
            self.wlr_cursor.y;

    server.seat.cursor.state = .{
        .resize = .{
            .toplevel = toplevel,
            .edges = edges,
            // OH NO...
            .x_offset = edge_x - self.wlr_cursor.x,
            .y_offset = edge_y - self.wlr_cursor.y,
        },
    };
}

pub fn setSurface(self: *Self, surface: ?*wlr.Surface, hotspot_x: i32, hotspot_y: i32) void {
    switch (self.state) {
        .passthrough => self.wlr_cursor.setSurface(surface, hotspot_x, hotspot_y),
        .move, .resize => {},
    }
}

fn endMove(self: *Self, time_msec: u32) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    const focused = seat.focused_toplevel orelse return;
    const view_at = server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;

    focused.getWorkspace().swapTiles(focused, view_at.toplevel);
    server.applyWorkspaceLayout(focused.workspace_id);

    self.updatePassthrough(time_msec);
}

fn updatePassthrough(self: *Self, time_msec: u32) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    if (server.viewAt(self.wlr_cursor.x, self.wlr_cursor.y)) |res| {
        seat.pointerNotifyEnter(res.surface, res.sx, res.sy, time_msec);
    } else {
        self.wlr_cursor.setXcursor(server.cursor_mgr, "default");
        seat.pointerNotifyExit();
    }
}

fn updateResize(self: *Self, toplevel: *Toplevel, x_offset: f64, y_offset: f64, edges: wlr.Edges) void {
    const seat = self.getSeat();
    const server = seat.getServer();

    const workspace = toplevel.getWorkspace();

    const output = server.output_layout.outputAt(self.wlr_cursor.x, self.wlr_cursor.y) orelse return;
    var layout_dirty = false;

    const x = self.wlr_cursor.x + x_offset;
    const y = self.wlr_cursor.y + y_offset;
    if ((toplevel.index != 0 and edges.left) or
        (toplevel.index == 0 and edges.right))
    {
        workspace.horizontal_ratio = x / @as(f64, @floatFromInt(output.width));
        layout_dirty = true;
    }

    if (toplevel.index > 1 and edges.top) {
        const prev = workspace.toplevels.items[toplevel.index - 1];
        prev.getWorkspace().resizeTile(prev, y);
        layout_dirty = true;
    }

    if (toplevel.index != 0 and
        toplevel.index != workspace.len() - 1 and
        edges.bottom)
    {
        workspace.resizeTile(toplevel, y);
        layout_dirty = true;
    }

    if (layout_dirty == true) {
        server.applyWorkspaceLayout(toplevel.workspace_id);
    }
}
