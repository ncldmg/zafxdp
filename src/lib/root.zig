// ZAFXDP - Zig AF_XDP Library
// Main module that re-exports all public APIs

// Import submodules
const xsk = @import("xsk.zig");
const loader = @import("loader.zig");
const protocol = @import("protocol.zig");
const packet = @import("packet.zig");
const processor = @import("processor.zig");
const pipeline = @import("pipeline.zig");
const stats = @import("stats.zig");
const service = @import("service.zig");

// Re-export XDP Socket APIs (low-level)
pub const XDPSocket = xsk.XDPSocket;
pub const SocketOptions = xsk.SocketOptions;
pub const XDPDesc = xsk.XDPDesc;

// Re-export eBPF Loader APIs (low-level)
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

// Re-export Protocol Parsers (high-level API)
pub const EthernetHeader = protocol.EthernetHeader;
pub const IPv4Header = protocol.IPv4Header;
pub const TcpHeader = protocol.TcpHeader;
pub const UdpHeader = protocol.UdpHeader;
pub const IcmpHeader = protocol.IcmpHeader;
pub const ArpHeader = protocol.ArpHeader;
pub const EtherType = protocol.EtherType;
pub const IpProtocol = protocol.IpProtocol;
pub const TcpFlags = protocol.TcpFlags;

// Re-export Packet API (high-level API)
pub const Packet = packet.Packet;
pub const PacketSource = packet.PacketSource;
pub const PacketMetadata = packet.PacketMetadata;

// Re-export Processor API (high-level API)
pub const PacketProcessor = processor.PacketProcessor;
pub const PacketAction = processor.PacketAction;
pub const ProcessResult = processor.ProcessResult;
pub const TransmitTarget = processor.TransmitTarget;

// Re-export Pipeline API (high-level API)
pub const Pipeline = pipeline.Pipeline;
pub const PipelineConfig = pipeline.PipelineConfig;

// Re-export Stats API (high-level API)
pub const ServiceStats = stats.ServiceStats;
pub const StatsSnapshot = stats.StatsSnapshot;

// Re-export Service API (high-level API)
pub const Service = service.Service;
pub const ServiceConfig = service.ServiceConfig;
pub const InterfaceConfig = service.InterfaceConfig;
pub const getInterfaceIndex = service.getInterfaceIndex;

// For testing
test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(xsk);
    @import("std").testing.refAllDecls(loader);
}
