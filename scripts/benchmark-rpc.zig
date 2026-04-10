//! CLI-Tool zum Senden von RPC-Benchmark-Kommandos an vulkan-ed
//!
//! Usage:
//!   zig run scripts/benchmark-rpc.zig -- <file_path> [iterations]
//!
//! Example:
//!   zig run scripts/benchmark-rpc.zig -- src/main.zig 20

const std = @import("std");

const RPC_HOST = "127.0.0.1";
const RPC_PORT = 9999;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print(
            \\Usage: zig run scripts/benchmark-rpc.zig -- <file_path> [iterations]
            \\
            \\Sends benchmark RPC command to vulkan-ed (must be running with --e2e flag)
            \\
            \\Arguments:
            \\  file_path   Path to file to benchmark (required)
            \\  iterations  Number of iterations (default: 10, max: 100)
            \\
            \\Example:
            \\  zig run scripts/benchmark-rpc.zig -- src/main.zig 20
            \\
        , .{});
        std.process.exit(1);
    }

    const file_path = args[1];
    const iterations: i64 = if (args.len >= 3)
        std.fmt.parseInt(i64, args[2], 10) catch {
            std.debug.print("Error: Invalid iterations number: {s}\n", .{args[2]});
            std.process.exit(1);
        }
    else
        10;

    std.debug.print("Benchmarking: {s} ({d} iterations)\n", .{ file_path, iterations });

    // Benchmark mode: load_file (misst readFileAlloc + setText)
    const method = "benchmark_load_file";

    // RPC JSON-RPC Request bauen
    var request_buf: [1024]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf,
        \\{{"jsonrpc": "2.0", "method": "{s}", "params": ["{s}", {d}], "id": 1}}
    , .{ method, file_path, iterations });

    // Verbindung herstellen
    const address = try std.net.Address.parseIp4(RPC_HOST, RPC_PORT);
    var stream = std.net.tcpConnectToAddress(address) catch {
        std.debug.print("Error: Cannot connect to vulkan-ed RPC server at {s}:{d}\n", .{ RPC_HOST, RPC_PORT });
        std.debug.print("Make sure vulkan-ed is running with --e2e flag\n", .{});
        std.process.exit(1);
    };
    defer stream.close();

    const read_buf: [4096]u8 = undefined;
    _ = read_buf;

    // Request senden (mit Newline als Delimiter)
    var request_buf2: [1024]u8 = undefined;
    const request_len = request.len;
    @memcpy(request_buf2[0..request_len], request);
    request_buf2[request_len] = '\n';
    try stream.writeAll(request_buf2[0 .. request_len + 1]);

    // Antwort lesen
    var response_buf: [4096]u8 = undefined;
    const bytes_read = try stream.read(&response_buf);

    if (bytes_read == 0) {
        std.debug.print("Error: Empty response from server\n", .{});
        std.process.exit(1);
    }

    // Antwort parsen
    const response = response_buf[0..bytes_read];

    // JSON-RPC Response parsen (einfacher Parser ohne JSON-Lib)
    if (std.mem.indexOf(u8, response, "\"error\"")) |_| {
        std.debug.print("RPC Error: {s}\n", .{response});
        std.process.exit(1);
    }

    // Result-Feld extrahieren
    if (std.mem.indexOf(u8, response, "\"result\":")) |result_start| {
        const json_start = result_start + 9; // length of "result":
        // Finde das Ende (matching braces)
        var brace_count: i32 = 0;
        var json_end: usize = json_start;
        for (response[json_start..], json_start..) |byte, i| {
            if (byte == '{') brace_count += 1;
            if (byte == '}') {
                brace_count -= 1;
                if (brace_count == 0) {
                    json_end = i + 1;
                    break;
                }
            }
        }

        const result_json = response[json_start..json_end];

        // Statistics extrahieren und formatiert ausgeben
        printStats(result_json) catch |err| {
            std.debug.print("printStats error: {}\n", .{err});
        };
    } else {
        std.debug.print("Response: {s}\n", .{response});
    }
}

/// Statistik-Werte aus JSON extrahieren und formatiert ausgeben
fn printStats(json: []const u8) !void {
    std.debug.print("\n{s}\n", .{"─" ** 60});
    std.debug.print("  Benchmark Results\n", .{});
    std.debug.print("{s}\n", .{"─" ** 60});

    // File size first (escaped quotes im JSON-String)
    if (std.mem.indexOf(u8, json, "\\\"file_size_bytes\\\":" )) |pos| {
        const value_start = pos + 21; // len of \"file_size_bytes\":
        var vs = value_start;
        while (vs < json.len and (json[vs] == ' ' or json[vs] == '\t')) : (vs += 1) {}
        var ve = vs;
        while (ve < json.len and json[ve] != ',' and json[ve] != '}') : (ve += 1) {}
        const value = json[vs..ve];
        const size_bytes = std.fmt.parseInt(u64, value, 10) catch 0;
        const size_kb = @as(f64, @floatFromInt(size_bytes)) / 1024.0;
        const size_mb = size_kb / 1024.0;
        if (size_mb >= 1.0) {
            std.debug.print("  {s:>8}: {d:.2} MB\n", .{ "Size", size_mb });
        } else {
            std.debug.print("  {s:>8}: {d:.1} KB\n", .{ "Size", size_kb });
        }
    }

    inline for (.{
        .{ "first_load_ms", "First" },
        .{ "min_ms", "Min" },
        .{ "max_ms", "Max" },
        .{ "avg_ms", "Avg" },
        .{ "total_ms", "Total" },
    }) |field| {
        const key = field[0];
        const label = field[1];
        // Suche nach \"key\": (mit escaped quotes)
        const search_key = "\\\"" ++ key ++ "\\\":";
        if (std.mem.indexOf(u8, json, search_key)) |pos| {
            const value_start = pos + search_key.len;
            // Whitespace überspringen
            var vs = value_start;
            while (vs < json.len and (json[vs] == ' ' or json[vs] == '\t')) : (vs += 1) {}
            // Finde Ende (Komma oder schließende Klammer)
            var ve = vs;
            while (ve < json.len and json[ve] != ',' and json[ve] != '}') : (ve += 1) {}
            const value = json[vs..ve];

            std.debug.print("  {s:>8}: {s} ms\n", .{ label, value });
        }
    }

    std.debug.print("{s}\n", .{"─" ** 60});
}
