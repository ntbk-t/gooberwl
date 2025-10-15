const Self = @This();

const std = @import("std");
const gpa = std.heap.c_allocator;

const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

xdg_popup: *wlr.XdgPopup,

commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
destroy: wl.Listener(void) = .init(handleDestroy),

fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
    const popup: *Self = @fieldParentPtr("commit", listener);
    if (popup.xdg_popup.base.initial_commit) {
        _ = popup.xdg_popup.base.scheduleConfigure();
    }
}

fn handleDestroy(listener: *wl.Listener(void)) void {
    const popup: *Self = @fieldParentPtr("destroy", listener);

    popup.commit.link.remove();
    popup.destroy.link.remove();

    gpa.destroy(popup);
}
