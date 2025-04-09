const std = @import("std");
const ai = @import("ai.zig");
// Import event-based I/O
const os = std.os;
const net = std.net;
const posix = std.posix;

// Define the bot token and chat ID
const bot_token = "";
const chat_id = "";

// Set a timeout for the socket
const TIMEOUT_MS = 5; // 5 seconds timeout
// Alternative: Use async operations with timeout
const TIMEOUT_NS = 5 * std.time.ns_per_s; // 5 seconds

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mistral: ai.MistralAI = .{};
    try mistral.init(allocator, ""[0..]);

    const http_read_buffer = try allocator.alloc(u8, 1e4);
    var server_address = try std.net.Address.resolveIp("127.0.0.1", 8081);

    const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(server_address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &server_address.any, server_address.getOsSockLen());
    try posix.listen(listener, 128);

    // Create a timeout using poll
    var pollfd = [1]std.posix.pollfd{
        .{
            .fd = listener,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    while (true) {
        // Wait for data with timeout
        const poll_result = std.posix.poll(&pollfd, TIMEOUT_MS) catch |err| {
            std.debug.print("Poll error: {}\n", .{err});
            continue;
        };

        if (poll_result == 0) {
            // No data available
            const reminders = try mistral.GetRemindersToSend(allocator);
            for (reminders.items) |reminder| {
                try send_to_telegram(allocator, reminder.items);
            }
            continue; // Or handle timeout as needed
        }

        const socket = posix.accept(listener, null, null, 0) catch continue;
        defer posix.close(socket);

        const read_bytes = posix.read(socket, http_read_buffer) catch continue;
        if (read_bytes == 0) {
            continue; // connection is no longer valid
        }
        if (std.mem.indexOf(u8, http_read_buffer[0..read_bytes], "\r\n\r\n")) |body_index| { // header and body are seperated by an empty line
            const request_body = http_read_buffer[body_index + 4 .. read_bytes];
            std.debug.print("Request body: {s}\n", .{request_body});
            const reminder = mistral.CreateReminder(allocator, request_body) catch {
                std.debug.print("Error occured parsing request {s}", .{http_read_buffer});
                _ = posix.write(socket, "HTTP/1.1 500 UNKNOWN_ERROR\r\nContent-Type: text/plain\r\n\r\nFailed to parse mistral ai response.") catch continue;
                continue;
            };
            std.debug.print("Reminder received: {s}\n", .{reminder.reminder_text.items});
            // try send_to_telegram(allocator, reminder.reminder_text.items);
            _ = posix.write(socket, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nMessage sent to Telegram bot.") catch continue;
        } else {
            std.debug.print("Received invalid request {s}", .{http_read_buffer});
            _ = posix.write(socket, "HTTP/1.1 500 INVALID_REQUEST\r\nContent-Type: text/plain\r\n\r\nMissing request body") catch continue;
        }
    }
}

fn send_to_telegram(allocator: std.mem.Allocator, content: []const u8) !void {
    const url = "https://api.telegram.org/bot" ++ bot_token ++ "/sendMessage";
    // Create a HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var response_body = std.ArrayList(u8).init(allocator);
    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const body = try std.fmt.allocPrint(allocator, "{{ \"chat_id\": {s}, \"text\": \"{s}\" }}", .{ chat_id, content });
    defer allocator.free(body);
    std.debug.print("Content: {s}\n", .{body});
    const response = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = url },
        .extra_headers = headers, //put these here instead of .headers
        .response_storage = .{ .dynamic = &response_body }, // this allows us to get a response of unknown size
        .payload = body,
    });

    std.debug.print("Response Status: {d}\n Response Body:{s}\n", .{ response.status, response_body.items });
}
