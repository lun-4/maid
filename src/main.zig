const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("notcurses/direct.h");
});

const logger = std.log.scoped(.maid);

fn draw_movable_box(nc: *c.ncplane) !*c.ncplane {
    var nopts = std.mem.zeroes(c.ncplane_options);
    nopts.y = 5;
    nopts.x = 5;
    nopts.rows = 5;
    nopts.cols = 5;

    var n_optional = c.ncplane_create(nc, &nopts);
    errdefer {
        _ = c.ncplane_destroy(n_optional);
    }
    if (n_optional) |plane| {
        _ = c.ncplane_set_fg_rgb8(plane, 255, 0, 255);
        var y: i32 = 0;

        while (y < 5) : (y += 1) {
            var x: i32 = 0;
            while (x < 5) : (x += 1) {
                if (c.ncplane_putchar_yx(plane, y, x, 'x') < 0) {
                    return error.FailedToDraw;
                }
            }
        }

        return plane;
    } else {
        return error.FailedToCreateTetrominoPlane;
    }
}

const CursorState = struct {
    plane_drag: bool = false,
};

const NOTCURSES_U32_ERROR = 4294967295;

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
    var nopts = std.mem.zeroes(c.notcurses_options);
    nopts.flags = c.NCOPTION_NO_ALTERNATE_SCREEN;
    nopts.flags |= c.NCOPTION_SUPPRESS_BANNERS;

    var nc_opt = c.notcurses_init(&nopts, c.stdout);
    if (nc_opt == null) return error.NoNotcursesContextProvided;
    var nc = nc_opt.?;
    defer {
        _ = c.notcurses_stop(nc);
    }

    const mouse_enabled_return = c.notcurses_mouse_enable(nc);
    if (mouse_enabled_return != 0) return error.FailedToEnableMouse;

    //var dimy: i32 = undefined;
    //var dimx: i32 = undefined;
    //var stdplane = c.notcurses_stddim_yx(nc, &dimy, &dimx).?;

    //var plane = try draw_movable_box(stdplane);
    //_ = c.notcurses_render(nc);

    //var cursor_state = CursorState{};

    while (true) {
        var inp: c.ncinput = undefined;
        const character = c.notcurses_getc_blocking(nc, &inp);
        if (character == NOTCURSES_U32_ERROR) {
            logger.err("Error: {s}", .{c.strerror(std.c._errno().*)});
            return error.FailedToGetInput;
        }

        //const plane_x = c.ncplane_x(plane);
        //const plane_y = c.ncplane_y(plane);

        //if (inp.id == c.NCKEY_RESIZE) {
        //    _ = c.notcurses_refresh(nc, null, null);
        //} else if (inp.evtype == c.NCTYPE_PRESS and inp.x == plane_x and inp.y == plane_y) {
        //    cursor_state.plane_drag = true;
        //} else if (inp.evtype == c.NCTYPE_RELEASE) {
        //    cursor_state.plane_drag = false;
        //} else if (inp.evtype == c.NCTYPE_PRESS and cursor_state.plane_drag == true) {
        //    _ = c.ncplane_move_yx(plane, inp.y, inp.x);
        //    _ = c.notcurses_render(nc);
        //}
    }
}
