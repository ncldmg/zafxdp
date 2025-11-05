const std = @import("std");
const xdp = @import("zafxdp_lib");
const cli = @import("cli");

// Import command modules
const receive_cmd = @import("commands/receive.zig");
const list_interfaces_cmd = @import("commands/list_interfaces.zig");

const VERSION = "0.1.0";

// Configuration structure with default values
var config = struct {
    interface: []const u8 = undefined,
    queue_id: u32 = 0,
    num_packets: ?u64 = null,
}{};

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);

    const app = cli.App{
        .version = VERSION,
        .author = "zafxdp contributors",
        .command = cli.Command{
            .name = "zafxdp",
            .description = cli.Description{
                .one_line = "AF_XDP Socket CLI for high-performance packet processing",
                .detailed =
                \\zafxdp provides tools for working with AF_XDP sockets in Linux.
                \\
                \\This program requires root privileges (sudo) to create BPF programs
                \\and attach XDP programs to network interfaces.
                ,
            },
            .target = cli.CommandTarget{
                .subcommands = &.{
                    // receive command
                    cli.Command{
                        .name = "receive",
                        .description = cli.Description{
                            .one_line = "Start receiving packets on the specified interface and queue",
                            .detailed =
                            \\Captures packets from a network interface using AF_XDP.
                            \\
                            \\Examples:
                            \\  sudo zafxdp receive --interface eth0 --queue 0
                            \\  sudo zafxdp receive -i lo -q 0 --num-packets 100
                            ,
                        },
                        .options = &.{
                            .{
                                .long_name = "interface",
                                .short_alias = 'i',
                                .help = "network interface name (e.g., eth0, lo)",
                                .required = true,
                                .value_ref = r.mkRef(&config.interface),
                            },
                            .{
                                .long_name = "queue",
                                .short_alias = 'q',
                                .help = "RX queue ID (default: 0)",
                                .value_ref = r.mkRef(&config.queue_id),
                            },
                            .{
                                .long_name = "num-packets",
                                .short_alias = 'n',
                                .help = "stop after receiving this many packets (unlimited if not specified)",
                                .value_ref = r.mkRef(&config.num_packets),
                            },
                        },
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{
                                .exec = receiveCommand,
                            },
                        },
                    },

                    // list-interfaces command
                    cli.Command{
                        .name = "list-interfaces",
                        .description = cli.Description{
                            .one_line = "List available network interfaces with their indices",
                        },
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{
                                .exec = listInterfacesCommand,
                            },
                        },
                    },
                },
            },
        },
    };

    return r.run(&app);
}

fn receiveCommand() !void {
    const cmd_config = receive_cmd.Config{
        .interface = config.interface,
        .queue_id = config.queue_id,
        .num_packets = config.num_packets,
    };
    try receive_cmd.execute(std.heap.page_allocator, cmd_config);
}

fn listInterfacesCommand() !void {
    try list_interfaces_cmd.execute(std.heap.page_allocator);
}
