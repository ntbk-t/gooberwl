const Self = @This();

const std = @import("std");
const posix = std.posix;
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Keyboard = @import("Keyboard.zig");
const Output = @import("Output.zig");
const Popup = @import("Popup.zig");
const Toplevel = @import("Toplevel.zig");
const Workspace = @import("Workspace.zig");

wl_server: *wl.Server,
backend: *wlr.Backend,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
scene: *wlr.Scene,

output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
new_output: wl.Listener(*wlr.Output) = .init(newOutput),

xdg_shell: *wlr.XdgShell,
new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),
toplevels: std.ArrayList(*Toplevel) = .empty,

seat: *wlr.Seat,
new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),
keyboards: wl.list.Head(Keyboard, .link) = undefined,

cursor: *wlr.Cursor,
cursor_mgr: *wlr.XcursorManager,
cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotion),
cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsolute),
cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButton),
cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxis),
cursor_frame: wl.Listener(*wlr.Cursor) = .init(cursorFrame),

focused_toplevel: ?*Toplevel = null,
cursor_mode: enum { passthrough, move, resize } = .passthrough,
resize_edges: wlr.Edges = .{},
click_serial: u32 = 0,

workspaces: [10]Workspace = @splat(.{}),
active_workspace: u8,

socket_buf: [11]u8,
socket_name: [:0]const u8,

pub fn init(self: *Self) !void {
    const wl_server = try wl.Server.create();
    const loop = wl_server.getEventLoop();
    const backend = try wlr.Backend.autocreate(loop, null);
    const renderer = try wlr.Renderer.autocreate(backend);
    const output_layout = try wlr.OutputLayout.create(wl_server);
    const scene = try wlr.Scene.create();
    self.* = .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = try wlr.Allocator.autocreate(backend, renderer),
        .scene = scene,
        .output_layout = output_layout,
        .scene_output_layout = try scene.attachOutputLayout(output_layout),
        .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
        .seat = try wlr.Seat.create(wl_server, "default"),
        .cursor = try wlr.Cursor.create(),
        .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        .socket_buf = undefined,
        .socket_name = undefined,
        .active_workspace = 0,
    };

    try self.renderer.initServer(wl_server);

    _ = try wlr.Compositor.create(self.wl_server, 6, self.renderer);
    _ = try wlr.Subcompositor.create(self.wl_server);
    _ = try wlr.DataDeviceManager.create(self.wl_server);

    self.backend.events.new_output.add(&self.new_output);

    self.xdg_shell.events.new_toplevel.add(&self.new_xdg_toplevel);
    self.xdg_shell.events.new_popup.add(&self.new_xdg_popup);

    self.backend.events.new_input.add(&self.new_input);
    self.seat.events.request_set_cursor.add(&self.request_set_cursor);
    self.seat.events.request_set_selection.add(&self.request_set_selection);
    self.keyboards.init();

    self.cursor.attachOutputLayout(self.output_layout);
    try self.cursor_mgr.load(1);
    self.cursor.events.motion.add(&self.cursor_motion);
    self.cursor.events.motion_absolute.add(&self.cursor_motion_absolute);
    self.cursor.events.button.add(&self.cursor_button);
    self.cursor.events.axis.add(&self.cursor_axis);
    self.cursor.events.frame.add(&self.cursor_frame);

    self.socket_name = try self.wl_server.addSocketAuto(&self.socket_buf);
}

pub fn deinit(self: *Self) void {
    self.wl_server.destroyClients();

    self.new_input.link.remove();
    self.new_output.link.remove();

    self.new_xdg_toplevel.link.remove();
    self.new_xdg_popup.link.remove();
    self.request_set_cursor.link.remove();
    self.request_set_selection.link.remove();
    self.cursor_motion.link.remove();
    self.cursor_motion_absolute.link.remove();
    self.cursor_button.link.remove();
    self.cursor_axis.link.remove();
    self.cursor_frame.link.remove();

    self.backend.destroy();
    self.wl_server.destroy();
}

fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("new_output", listener);

    Output.create(self, wlr_output) catch {
        std.log.err("failed to allocate new output", .{});
        wlr_output.destroy();
        return;
    };
}

fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    const self: *Self = @fieldParentPtr("new_xdg_toplevel", listener);
    const xdg_surface = xdg_toplevel.base;

    // Don't add the toplevel to self.toplevels until it is mapped
    const toplevel = gpa.create(Toplevel) catch {
        std.log.err("failed to allocate new toplevel", .{});
        return;
    };

    toplevel.* = .{
        .server = self,
        .xdg_toplevel = xdg_toplevel,
        .scene_tree = self.scene.tree.createSceneXdgSurface(xdg_surface) catch {
            gpa.destroy(toplevel);
            std.log.err("failed to allocate new toplevel", .{});
            return;
        },
        .workspace_id = self.active_workspace,
    };
    toplevel.scene_tree.node.data = toplevel;
    xdg_surface.data = toplevel.scene_tree;

    xdg_surface.surface.events.commit.add(&toplevel.commit);
    xdg_surface.surface.events.map.add(&toplevel.map);
    xdg_surface.surface.events.unmap.add(&toplevel.unmap);
    xdg_toplevel.events.destroy.add(&toplevel.destroy);
    xdg_toplevel.events.request_move.add(&toplevel.request_move);
    xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
}

fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
    const xdg_surface = xdg_popup.base;

    // These asserts are fine since tinywl.zig doesn't support anything else that can
    // make xdg popups (e.g. layer shell).
    const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
    const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
        // The xdg surface user data could be left null due to allocation failure.
        return;
    };
    const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
        std.log.err("failed to allocate xdg popup node", .{});
        return;
    };
    xdg_surface.data = scene_tree;

    const popup = gpa.create(Popup) catch {
        std.log.err("failed to allocate new popup", .{});
        return;
    };
    popup.* = .{
        .xdg_popup = xdg_popup,
    };

    xdg_surface.surface.events.commit.add(&popup.commit);
    xdg_popup.events.destroy.add(&popup.destroy);
}

const ViewAtResult = struct {
    toplevel: *Toplevel,
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
};

fn viewAt(self: *Self, lx: f64, ly: f64) ?ViewAtResult {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    if (self.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
        if (node.type != .buffer) return null;
        const scene_buffer = wlr.SceneBuffer.fromNode(node);
        const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

        var it: ?*wlr.SceneTree = node.parent;
        while (it) |n| : (it = n.node.parent) {
            if (@as(?*Toplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
                return ViewAtResult{
                    .toplevel = toplevel,
                    .surface = scene_surface.surface,
                    .sx = sx,
                    .sy = sy,
                };
            }
        }
    }
    return null;
}

pub fn focusView(self: *Self, toplevel: *Toplevel) void {
    const surface = toplevel.xdg_toplevel.base.surface;

    if (self.seat.keyboard_state.focused_surface) |previous_surface| {
        if (previous_surface == surface) return;
        if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
            _ = xdg_surface.role_data.toplevel.?.setActivated(false);
        }
    }

    if (self.focused_toplevel) |focused_toplevel| {
        _ = focused_toplevel.xdg_toplevel.setActivated(false);
    }

    _ = toplevel.xdg_toplevel.setActivated(true);
    self.focused_toplevel = toplevel;

    const wlr_keyboard = self.seat.getKeyboard() orelse return;
    self.seat.keyboardNotifyEnter(
        surface,
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );
}

fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const self: *Self = @fieldParentPtr("new_input", listener);
    switch (device.type) {
        .keyboard => Keyboard.create(self, device) catch |err| {
            std.log.err("failed to create keyboard: {}", .{err});
            return;
        },
        .pointer => self.cursor.attachInputDevice(device),
        else => {},
    }

    self.seat.setCapabilities(.{
        .pointer = true,
        .keyboard = self.keyboards.length() > 0,
    });
}

fn requestSetCursor(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
    event: *wlr.Seat.event.RequestSetCursor,
) void {
    const self: *Self = @fieldParentPtr("request_set_cursor", listener);
    if (event.seat_client == self.seat.pointer_state.focused_client)
        self.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

fn requestSetSelection(
    listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
    event: *wlr.Seat.event.RequestSetSelection,
) void {
    const self: *Self = @fieldParentPtr("request_set_selection", listener);
    self.seat.setSelection(event.source, event.serial);
}

fn cursorMotion(
    listener: *wl.Listener(*wlr.Pointer.event.Motion),
    event: *wlr.Pointer.event.Motion,
) void {
    const self: *Self = @fieldParentPtr("cursor_motion", listener);
    self.cursor.move(event.device, event.delta_x, event.delta_y);
    self.processCursorMotion(event.time_msec);
}

fn cursorMotionAbsolute(
    listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
    event: *wlr.Pointer.event.MotionAbsolute,
) void {
    const self: *Self = @fieldParentPtr("cursor_motion_absolute", listener);
    self.cursor.warpAbsolute(event.device, event.x, event.y);
    self.processCursorMotion(event.time_msec);
}

fn processCursorMotion(self: *Self, time_msec: u32) void {
    switch (self.cursor_mode) {
        .passthrough => self.processPassthrough(time_msec),
        .resize => self.processResize(),
        .move => {},
    }
}

fn processPassthrough(self: *Self, time_msec: u32) void {
    if (self.viewAt(self.cursor.x, self.cursor.y)) |res| {
        self.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
        self.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
    } else {
        self.cursor.setXcursor(self.cursor_mgr, "default");
        self.seat.pointerClearFocus();
    }
}

fn processResize(self: *Self) void {
    const toplevel = self.focused_toplevel orelse {
        std.log.warn("cursor mode set to resize, but no toplevel is focused!", .{});
        self.cursor_mode = .passthrough;
        return;
    };

    const output = self.output_layout.outputAt(self.cursor.x, self.cursor.y) orelse return;
    var layout_dirty = false;

    if ((toplevel.index != 0 and self.resize_edges.left) or
        (toplevel.index == 0 and self.resize_edges.right))
    {
        toplevel.getWorkspace().horizontal_ratio = self.cursor.x / @as(f64, @floatFromInt(output.width));
        layout_dirty = true;
    }

    if (toplevel.index > 1 and self.resize_edges.top) {
        const prev = toplevel.getWorkspace().toplevels.items[toplevel.index - 1];
        prev.getWorkspace().resizeTile(prev, self.cursor.y);
        layout_dirty = true;
    }

    if (toplevel.index != 0 and
        toplevel.index != self.toplevels.items.len - 1 and
        self.resize_edges.bottom)
    {
        toplevel.getWorkspace().resizeTile(toplevel, self.cursor.y);
        layout_dirty = true;
    }

    if (layout_dirty == true) {
        self.applyWorkspaceLayout(toplevel.workspace_id);
    }
}

fn cursorButton(
    listener: *wl.Listener(*wlr.Pointer.event.Button),
    event: *wlr.Pointer.event.Button,
) void {
    const self: *Self = @fieldParentPtr("cursor_button", listener);
    const serial = self.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    switch (event.state) {
        .pressed => {
            self.click_serial = serial;
            if (self.viewAt(self.cursor.x, self.cursor.y)) |res| {
                self.focusView(res.toplevel);
            }
        },
        .released => {
            switch (self.cursor_mode) {
                .passthrough => {},
                .move => self.processMove(),
                .resize => self.cursor_mode = .passthrough,
            }
            self.cursor_mode = .passthrough;
        },
        _ => {},
    }
}

fn processMove(self: *Self) void {
    const focused = self.focused_toplevel orelse return;
    const view_at = self.viewAt(self.cursor.x, self.cursor.y) orelse return;

    focused.getWorkspace().swapTiles(focused, view_at.toplevel);
}

fn cursorAxis(
    listener: *wl.Listener(*wlr.Pointer.event.Axis),
    event: *wlr.Pointer.event.Axis,
) void {
    const self: *Self = @fieldParentPtr("cursor_axis", listener);
    self.seat.pointerNotifyAxis(
        event.time_msec,
        event.orientation,
        event.delta,
        event.delta_discrete,
        event.source,
        event.relative_direction,
    );
}

fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const self: *Self = @fieldParentPtr("cursor_frame", listener);
    self.seat.pointerNotifyFrame();
}

pub fn getWorkspace(self: *Self, id: u8) *Workspace {
    return &self.workspaces[id];
}

pub fn getActiveWorkspace(self: *Self) *Workspace {
    return self.getWorkspace(self.active_workspace);
}

pub fn setWorkspace(self: *Self, id: u8) void {
    std.debug.assert(id < 10);

    self.getActiveWorkspace().hide();
    self.active_workspace = id;
    self.getActiveWorkspace().applyLayout();
}

pub fn applyWorkspaceLayout(self: *Self, id: u8) void {
    if (self.active_workspace == id) {
        self.getWorkspace(id).applyLayout();
    }
}

/// Assumes the modifier used for compositor keybinds is pressed
/// Returns true if the key was handled
pub fn handleKeybind(self: *Self, key: xkb.Keysym) bool {
    switch (@intFromEnum(key)) {
        xkb.Keysym.Escape => self.wl_server.terminate(),
        xkb.Keysym.Return => {
            var child = std.process.Child.init(&.{"alacritty"}, gpa);

            var env_map = std.process.getEnvMap(gpa) catch {
                std.log.err("failed to get environment map!", .{});
                return false;
            };
            defer env_map.deinit();

            env_map.put("WAYLAND_DISPLAY", self.socket_name) catch {
                std.log.err("failed to add WAYLAND_DISPLAY to environment map!", .{});
                return false;
            };
            child.env_map = &env_map;

            child.spawn() catch {
                std.log.err("failed to spawn terminal window!", .{});
                return false;
            };
        },
        xkb.Keysym.@"1" => self.setWorkspace(0),
        xkb.Keysym.@"2" => self.setWorkspace(1),
        xkb.Keysym.@"3" => self.setWorkspace(2),
        xkb.Keysym.@"4" => self.setWorkspace(3),
        xkb.Keysym.@"5" => self.setWorkspace(4),
        xkb.Keysym.@"6" => self.setWorkspace(5),
        xkb.Keysym.@"7" => self.setWorkspace(6),
        xkb.Keysym.@"8" => self.setWorkspace(7),
        xkb.Keysym.@"9" => self.setWorkspace(8),
        xkb.Keysym.@"0" => self.setWorkspace(9),
        else => return false,
    }
    return true;
}
