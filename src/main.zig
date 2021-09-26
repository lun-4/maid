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

const Pipe = struct {
    reader: std.fs.File,
    writer: std.fs.File,
};

const NOTCURSES_U32_ERROR = 4294967295;

var zig_segfault_handler: fn (i32, *const std.os.siginfo_t, ?*const c_void) callconv(.C) void = undefined;
var maybe_self_pipe: ?Pipe = null;

const SignalData = extern struct {
    signal: c_int,
    info: std.os.siginfo_t,
    uctx: ?*const c_void,
};
const SignalList = std.ArrayList(SignalData);

fn signal_handler(signal: c_int, info: *const std.os.siginfo_t, uctx: ?*const c_void) callconv(.C) void {
    if (maybe_self_pipe) |self_pipe| {
        const signal_data = SignalData{
            .signal = signal,
            .info = info.*,
            .uctx = uctx,
        };
        self_pipe.writer.writer().writeStruct(signal_data) catch return;
    }
}

const MainContext = struct {
    allocator: *std.mem.Allocator,
    nc: *c.notcurses,
    cursor_state: CursorState = .{},
    const Self = @This();

    fn processNewSignals(self: Self) !void {
        _ = self;
        while (true) {
            const signal_data = maybe_self_pipe.?.reader.reader().readStruct(SignalData) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (signal_data.signal == std.os.SIG.SEGV) {
                zig_segfault_handler(signal_data.signal, &signal_data.info, signal_data.uctx);
            } else {
                logger.info("exiting! with signal {d}", .{signal_data.signal});
                // TODO shutdown db, when we have one
                std.os.exit(1);
            }
        }
    }

    fn processTerminalEvents(self: *Self, plane: *c.ncplane) !void {
        while (true) {
            var inp: c.ncinput = undefined;
            const character = c.notcurses_getc_nblock(self.nc, &inp);
            if (character == 0) break;
            logger.info("input {}", .{inp});
            if (character == NOTCURSES_U32_ERROR) {
                logger.err("Error: {s}", .{c.strerror(std.c._errno().*)});
                return error.FailedToGetInput;
            }

            const plane_x = c.ncplane_x(plane);
            const plane_y = c.ncplane_y(plane);

            if (inp.id == c.NCKEY_RESIZE) {
                _ = c.notcurses_refresh(self.nc, null, null);
                _ = c.notcurses_render(self.nc);
            } else if (inp.evtype == c.NCTYPE_PRESS and inp.x == plane_x and inp.y == plane_y) {
                self.cursor_state.plane_drag = true;
            } else if (inp.evtype == c.NCTYPE_RELEASE) {
                self.cursor_state.plane_drag = false;
            } else if (inp.evtype == c.NCTYPE_PRESS and self.cursor_state.plane_drag == true) {
                _ = c.ncplane_move_yx(plane, inp.y, inp.x);
                _ = c.notcurses_render(self.nc);
            }
        }
    }
};

pub fn main() anyerror!void {
    // configure requirements for signal handling
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }

    const allocator = &gpa.allocator;
    const self_pipe_fds = try std.os.pipe();
    maybe_self_pipe = .{
        .reader = .{ .handle = self_pipe_fds[0] },
        .writer = .{ .handle = self_pipe_fds[1] },
    };
    defer {
        maybe_self_pipe.?.reader.close();
        maybe_self_pipe.?.writer.close();
    }

    // initialize the logfile, if given in LOGFILE env var
    const maybe_logfile_path = std.os.getenv("LOGFILE");
    if (maybe_logfile_path) |logfile_path| {
        logfile_optional = try std.fs.cwd().createFile(
            logfile_path,
            .{ .truncate = true, .read = false },
        );
    }

    defer {
        if (logfile_optional) |logfile| logfile.close();
    }

    // configure signal handler
    // Zig attaches a handler to SIGSEGV to provide pretty output on segfaults,
    // but we also want to attach our own shutdown code to other signals
    // like SIGINT, SIGTERM, etc.
    //
    // there can only be one signal handler declared in the system, so we
    // need to extract the zig signal handler, and call it on our own
    //
    // notcurses will do the same behavior but for the signal handler we
    // provide, so everything has a way to shutdown safely.
    //
    // NOTE: do not trust your engineering skills on safely shutting down
    // on a SIGSEGV. even on maid's signal handler, only signals we actually
    // want cause a safe DB shutdown.
    //
    // Engineer to always be safe, even on a hard power off.
    //
    // Our signal handler uses the self-pipe trick to provide DB shutdown
    // on a CTRL-C while also mainaining overall non-blocking I/O structure
    // in code.

    var mask = std.os.empty_sigset;
    // only linux and darwin implement sigaddset() on zig stdlib. huh.
    std.os.linux.sigaddset(&mask, std.os.SIG.TERM);
    std.os.linux.sigaddset(&mask, std.os.SIG.INT);
    var sa = std.os.Sigaction{
        .handler = .{ .sigaction = signal_handler },
        .mask = mask,
        .flags = 0,
    };

    // declare handler for SIGSEGV, catching the "old" one
    // (zig sets its own BEFORE calling main(), see lib/std/start.zig)
    var old_sa: std.os.Sigaction = undefined;
    std.os.sigaction(std.os.SIG.SEGV, &sa, &old_sa);
    zig_segfault_handler = old_sa.handler.sigaction.?;
    std.os.sigaction(std.os.SIG.TERM, &sa, null);
    std.os.sigaction(std.os.SIG.INT, &sa, null);

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

    // our main loop is basically polling for stdin and the signal selfpipe.
    //
    // if stdin has data, let notcurses consume it, keep it in a loop so
    // 	all possible events are consumed, instead of a single one (which would
    // 	cause drift)
    //
    // if signal selfpipe has data, consume it from the signal queue.
    // 	if we get a SIGSEGV, call zig_segfault_handler

    const PollFdList = std.ArrayList(std.os.pollfd);
    var sockets = PollFdList.init(allocator);
    defer sockets.deinit();

    const stdin_fd = std.io.getStdIn().handle;

    try sockets.append(std.os.pollfd{
        .fd = stdin_fd,
        .events = std.os.POLL.IN,
        .revents = 0,
    });
    try sockets.append(std.os.pollfd{
        .fd = maybe_self_pipe.?.reader.handle,
        .events = std.os.POLL.IN,
        .revents = 0,
    });

    var ctx = MainContext{ .nc = nc, .allocator = allocator };

    // TODO logging main() errors back to logger handler

    while (true) {
        logger.info("poll!", .{});
        const available = try std.os.poll(sockets.items, -1);
        try std.testing.expect(available > 0);
        for (sockets.items) |pollfd| {
            if (pollfd.revents == 0) continue;

            // signals have higher priority, as if we got a SIGTERM,
            // notcurses WILL have destroyed its context and resetted the
            // terminal to a good state, which means we must not render shit.
            if (pollfd.fd == maybe_self_pipe.?.reader.handle) {
                try ctx.processNewSignals();
            }

            if (pollfd.fd == stdin_fd) {
                try ctx.processTerminalEvents(plane);
            }
        }
    }
}
