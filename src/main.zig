const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("notcurses/direct.h");
});

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
    var nc_opt = c.ncdirect_init(null, c.stdout, 0);
    if (nc_opt == null) return error.NoNotcursesContextProvided;
    var nc = nc_opt.?;
    defer {
        _ = c.ncdirect_stop(nc);
    }
    try std.testing.expect(c.ncdirect_set_bg_rgb8(nc, 255, 0, 255) == 0);
    std.log.info("All your codebase are belong to us.", .{});
}
