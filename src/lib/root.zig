// ZAFXDP - Zig AF_XDP Library
// Main module that re-exports all public APIs

// Import submodules
const xsk = @import("xsk.zig");
const loader = @import("loader.zig");

// Re-export XDP Socket APIs
pub const XDPSocket = xsk.XDPSocket;
pub const SocketOptions = xsk.SocketOptions;
pub const XDPDesc = xsk.XDPDesc;

// Re-export eBPF Loader APIs
pub const EbpfLoader = loader.EbpfLoader;
pub const Program = loader.Program;
pub const LoaderError = loader.LoaderError;
pub const ProgramInfo = loader.ProgramInfo;
pub const MapInfo = loader.MapInfo;
pub const XdpFlags = loader.XdpFlags;
pub const DefaultXdpFlags = loader.DefaultXdpFlags;

// Re-export utility functions
pub const loadAfXdpProgram = loader.loadAfXdpProgram;
pub const printLoaderStatus = loader.printLoaderStatus;

// For testing
test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(xsk);
    @import("std").testing.refAllDecls(loader);
}
