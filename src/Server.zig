const Self = @This();

const std = @import("std");
const posix = std.posix;
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Keyboard = @import("seat/Keyboard.zig");
const Output = @import("Output.zig");
const Popup = @import("Popup.zig");
const Toplevel = @import("Toplevel.zig");
const Workspace = @import("Workspace.zig");
const Seat = @import("seat/Seat.zig");

wl_server: *wl.Server,
backend: *wlr.Backend,
renderer: *wlr.Renderer,
allocator: *wlr.Allocator,
scene: *wlr.Scene,
output_layout: *wlr.OutputLayout,
scene_output_layout: *wlr.SceneOutputLayout,
xdg_shell: *wlr.XdgShell,

toplevels: std.ArrayList(*Toplevel) = .empty,
seat: Seat,
cursor_mgr: *wlr.XcursorManager,

on_new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
on_new_output: wl.Listener(*wlr.Output) = .init(newOutput),
on_new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
on_new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),

workspaces: [10]Workspace = @splat(.{}),
active_workspace: u8,

socket_buf: [11]u8,
socket_name: [:0]const u8,

pub fn init() !Self {
    const wl_server = try wl.Server.create();
    const backend = try wlr.Backend.autocreate(wl_server.getEventLoop(), null);
    const renderer = try wlr.Renderer.autocreate(backend);
    const output_layout = try wlr.OutputLayout.create(wl_server);
    const scene = try wlr.Scene.create();
    return .{
        .wl_server = wl_server,
        .backend = backend,
        .renderer = renderer,
        .allocator = try .autocreate(backend, renderer),
        .scene = scene,
        .output_layout = output_layout,
        .scene_output_layout = try scene.attachOutputLayout(output_layout),
        .xdg_shell = try .create(wl_server, 2),
        .seat = try .init(wl_server, "default"),
        .cursor_mgr = try .create(null, 24),
        .socket_buf = undefined,
        .socket_name = undefined,
        .active_workspace = 0,
    };
}

pub fn start(self: *Self) !void {
    try self.renderer.initServer(self.wl_server);

    _ = try wlr.Compositor.create(self.wl_server, 6, self.renderer);
    _ = try wlr.Subcompositor.create(self.wl_server);
    _ = try wlr.DataDeviceManager.create(self.wl_server);

    self.backend.events.new_input.add(&self.on_new_input);
    self.backend.events.new_output.add(&self.on_new_output);

    self.xdg_shell.events.new_toplevel.add(&self.on_new_xdg_toplevel);
    self.xdg_shell.events.new_popup.add(&self.on_new_xdg_popup);

    self.seat.start();

    self.seat.cursor.wlr_cursor.attachOutputLayout(self.output_layout);
    try self.cursor_mgr.load(1);

    self.socket_name = try self.wl_server.addSocketAuto(&self.socket_buf);

    try self.backend.start();
    self.wl_server.run();
}

pub fn deinit(self: *Self) void {
    self.wl_server.destroyClients();

    self.on_new_input.link.remove();
    self.on_new_output.link.remove();

    self.on_new_xdg_toplevel.link.remove();
    self.on_new_xdg_popup.link.remove();

    self.seat.deinit();

    self.backend.destroy();
    self.wl_server.destroy();
}

fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
    const self: *Self = @fieldParentPtr("on_new_output", listener);

    Output.create(self, wlr_output) catch {
        std.log.err("failed to allocate new output", .{});
        wlr_output.destroy();
        return;
    };
}

fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
    const self: *Self = @fieldParentPtr("on_new_xdg_toplevel", listener);

    Toplevel.create(self, xdg_toplevel) catch {
        xdg_toplevel.sendClose();
    };
}

fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
    Popup.create(xdg_popup) catch {
        xdg_popup.destroy();
    };
}

const ViewAtResult = struct {
    toplevel: *Toplevel,
    surface: *wlr.Surface,
    sx: f64,
    sy: f64,
};

pub fn viewAt(self: *Self, lx: f64, ly: f64) ?ViewAtResult {
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

    if (self.seat.wlr_seat.keyboard_state.focused_surface) |previous_surface| {
        if (previous_surface == surface) return;
        if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
            _ = xdg_surface.role_data.toplevel.?.setActivated(false);
        }
    }

    if (self.seat.focused_toplevel) |focused_toplevel| {
        _ = focused_toplevel.xdg_toplevel.setActivated(false);
    }

    _ = toplevel.xdg_toplevel.setActivated(true);
    self.seat.focused_toplevel = toplevel;

    const wlr_keyboard = self.seat.wlr_seat.getKeyboard() orelse return;
    self.seat.wlr_seat.keyboardNotifyEnter(
        surface,
        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
        &wlr_keyboard.modifiers,
    );
}

fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const self: *Self = @fieldParentPtr("on_new_input", listener);
    self.seat.addInput(device);
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
