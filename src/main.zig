const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("notcurses/direct.h");
});

const logger = std.log.scoped(.maid);

var logfile_optional: ?std.fs.File = null;

// based on the default std.log impl
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    // if no logfile, prefer stderr
    const stream = if (logfile_optional) |logfile| logfile.writer() else std.io.getStdErr().writer();
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    nosuspend stream.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
}

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

var zig_segfault_handler: fn (i32, *const std.os.linux.siginfo_t, ?*const c_void) callconv(.C) void = undefined;

fn quit_handler(signal: c_int, info: *const std.os.linux.siginfo_t, uctx: ?*const c_void) callconv(.C) void {
    if (signal == std.os.linux.SIG.SEGV) {
        zig_segfault_handler(signal, info, uctx);
    } else {
        logger.info("exiting! {d}", .{signal});
        std.os.exit(1);
    }
}

pub fn main() anyerror!void {
    const logfile_path = std.os.getenv("LOGFILE");
    if (logfile_path != null) {
        logfile_optional = try std.fs.cwd().createFile(
            logfile_path.?,
            .{ .truncate = true, .read = false },
        );
    }

    defer {
        if (logfile_optional) |logfile| logfile.close();
    }

    // configure signals

    var mask = std.os.linux.empty_sigset;
    std.os.linux.sigaddset(&mask, std.os.SIG.TERM);
    std.os.linux.sigaddset(&mask, std.os.SIG.INT);
    var sa = std.os.Sigaction{
        .handler = .{ .sigaction = quit_handler },
        .mask = mask,
        .flags = 0,
    };

    var old_sa: std.os.Sigaction = undefined;

    _ = std.os.linux.sigaction(std.os.linux.SIG.SEGV, &sa, &old_sa);
    zig_segfault_handler = old_sa.handler.sigaction.?;
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &sa, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &sa, null);

    std.log.info("boot!", .{});
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

    var dimy: i32 = undefined;
    var dimx: i32 = undefined;
    var stdplane = c.notcurses_stddim_yx(nc, &dimy, &dimx).?;

    var plane = try draw_movable_box(stdplane);
    _ = c.notcurses_render(nc);

    var cursor_state = CursorState{};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;
    const PollFdList = std.ArrayList(std.os.pollfd);
    var sockets = PollFdList.init(allocator);
    defer sockets.deinit();

    const stdin_fd = std.io.getStdIn().handle;

    try sockets.append(std.os.pollfd{
        .fd = stdin_fd,
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    });

    // TODO logging main() errors back to logger handler

    while (true) {
        logger.info("poll!", .{});
        const available = try std.os.poll(sockets.items, -1);
        var must_read_terminal: bool = false;
        try std.testing.expect(available > 0);
        for (sockets.items) |pollfd| {
            if (pollfd.revents == 0) continue;
            if (pollfd.fd == stdin_fd) {
                // we have stuff on stdin to read.
                must_read_terminal = true;
            }
        }
        logger.info("polled! {}", .{must_read_terminal});

        while (must_read_terminal) {
            var inp: c.ncinput = undefined;
            const character = c.notcurses_getc_nblock(nc, &inp);
            if (character == 0) break;
            logger.info("input {}", .{inp});
            if (character == NOTCURSES_U32_ERROR) {
                logger.err("Error: {s}", .{c.strerror(std.c._errno().*)});
                return error.FailedToGetInput;
            }

            const plane_x = c.ncplane_x(plane);
            const plane_y = c.ncplane_y(plane);

            if (inp.id == c.NCKEY_RESIZE) {
                _ = c.notcurses_refresh(nc, null, null);
            } else if (inp.evtype == c.NCTYPE_PRESS and inp.x == plane_x and inp.y == plane_y) {
                cursor_state.plane_drag = true;
            } else if (inp.evtype == c.NCTYPE_RELEASE) {
                cursor_state.plane_drag = false;
            } else if (inp.evtype == c.NCTYPE_PRESS and cursor_state.plane_drag == true) {
                _ = c.ncplane_move_yx(plane, inp.y, inp.x);
                _ = c.notcurses_render(nc);
            }
        }
    }
}
