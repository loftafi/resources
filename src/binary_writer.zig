pub inline fn append_u64(data: *ArrayListUnmanaged(u8), value: u64, allocator: Allocator) error{OutOfMemory}!void {
    try data.append(allocator, @intCast(value & 0xff));
    try data.append(allocator, @intCast((value >> 8) & 0xff));
    try data.append(allocator, @intCast((value >> 16) & 0xff));
    try data.append(allocator, @intCast((value >> 24) & 0xff));
    try data.append(allocator, @intCast((value >> 32) & 0xff));
    try data.append(allocator, @intCast((value >> 40) & 0xff));
    try data.append(allocator, @intCast((value >> 48) & 0xff));
    try data.append(allocator, @intCast((value >> 56) & 0xff));
}

pub inline fn append_u32(data: *ArrayListUnmanaged(u8), value: u32, allocator: Allocator) error{OutOfMemory}!void {
    try data.append(allocator, @intCast(value & 0xff));
    try data.append(allocator, @intCast((value >> 8) & 0xff));
    try data.append(allocator, @intCast((value >> 16) & 0xff));
    try data.append(allocator, @intCast((value >> 24) & 0xff));
}

pub inline fn append_u24(data: *ArrayListUnmanaged(u8), value: u24, allocator: Allocator) error{OutOfMemory}!void {
    try data.append(allocator, @intCast(value & 0xff));
    try data.append(allocator, @intCast((value >> 8) & 0xff));
    try data.append(allocator, @intCast((value >> 16) & 0xff));
}

pub inline fn append_u16(data: *ArrayListUnmanaged(u8), value: u32, allocator: Allocator) error{OutOfMemory}!void {
    std.debug.assert(value <= 0xffff);
    try data.append(allocator, @intCast(value & 0xff));
    try data.append(allocator, @intCast((value >> 8) & 0xff));
}

pub inline fn append_u8(data: *ArrayListUnmanaged(u8), value: u32, allocator: Allocator) error{OutOfMemory}!void {
    std.debug.assert(value <= 0xff);
    try data.append(allocator, @intCast(value));
}

pub const SPACE = ' ';
pub const TAB = '\t';
pub const CR = '\r';
pub const LF = '\n';
pub const FS = 28; // File separator
pub const GS = 29; // Group (table) separator
pub const RS = 30; // Record separator
pub const US = 31; // Field (record) separator

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
