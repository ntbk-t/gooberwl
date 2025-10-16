const Self = @This();

const std = @import("std");
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const Seat = @import("Seat.zig");
const Server = @import("../Server.zig");

wlr_keyboard: *wlr.Keyboard,
seat: *Seat,

modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),
key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

pub fn create(seat: *Seat, wlr_keyboard: *wlr.Keyboard) !void {
    const keyboard = try gpa.create(Self);
    errdefer gpa.destroy(keyboard);

    keyboard.* = .{
        .wlr_keyboard = wlr_keyboard,
        .seat = seat,
    };

    const context = xkb.Context.new(.no_flags) orelse return error.ContextFailed;
    defer context.unref();
    const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.KeymapFailed;
    defer keymap.unref();

    if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
    wlr_keyboard.setRepeatInfo(25, 600);

    wlr_keyboard.events.modifiers.add(&keyboard.modifiers);
    wlr_keyboard.events.key.add(&keyboard.key);
    wlr_keyboard.base.events.destroy.add(&keyboard.destroy);

    seat.wlr_seat.setKeyboard(wlr_keyboard);
    seat.keyboards += 1;
}

fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const keyboard: *Self = @fieldParentPtr("modifiers", listener);
    keyboard.seat.wlr_seat.setKeyboard(wlr_keyboard);
    keyboard.seat.wlr_seat.keyboardNotifyModifiers(&wlr_keyboard.modifiers);
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    const self: *Self = @fieldParentPtr("key", listener);

    // Translate libinput keycode -> xkbcommon
    const keycode = event.keycode + 8;

    var handled = false;
    if (self.wlr_keyboard.getModifiers().alt and event.state == .pressed) {
        for (self.wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
            if (self.seat.getServer().handleKeybind(sym)) {
                handled = true;
                break;
            }
        }
    }

    if (!handled) {
        self.seat.wlr_seat.setKeyboard(self.wlr_keyboard);
        self.seat.wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }
}

fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
    const self: *Self = @fieldParentPtr("destroy", listener);

    self.modifiers.link.remove();
    self.key.link.remove();
    self.destroy.link.remove();

    gpa.destroy(self);
}
