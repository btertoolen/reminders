const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const http_read_buffer = try allocator.alloc(u8, 1e4);
    var server_address = try std.net.Address.resolveIp("127.0.0.1", 8081);
    var server = try server_address.listen(.{});
    defer server.deinit();
    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();
        var http_server = std.http.Server.init(connection, http_read_buffer);
        var request = http_server.receiveHead() catch continue;
        const reader = try request.reader();
        const buffer = try reader.readAllAlloc(allocator, 200);
        std.debug.print("Buffer: {s}\n", .{buffer});
        // Send the content to the Telegram bot
        try send_to_telegram(allocator, buffer);

        // try connection.writer().writeAll(
        //     "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nMessage sent to Telegram bot.",
        // );

        _ = request.respond("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nMessage sent to Telegram bot.", .{}) catch unreachable;
    }
}

fn send_to_telegram(allocator: std.mem.Allocator, content: []const u8) !void {
    const url = "https://api.telegram.org/bot" ++ bot_token ++ "/sendMessage";
    // Create a HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // // Allocate a buffer for server headers
    // var buf: [4096]u8 = undefined;

    // Start the HTTP request
    // const uri = try std.Uri.parse(url);
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
        // if we were doing a post request we would include the payload here
        .payload = body,
    });

    std.debug.print("Response Status: {d}\n Response Body:{s}\n", .{ response.status, response_body.items });

    // std.debug.print("Url: {s}\n", .{url});
    // var request = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
    // defer request.deinit();

    // try request.writeAll(body);
    // try request.finish();
    // std.debug.print("status={d}\n", .{request.response.status});

    // // Send the request
    // const response = try std.http.send(allocator, &request);
    // defer response.deinit();

    // Handle the response (optional)
    // if (@intFromEnum(request.response.status) != 200) {
    //     std.debug.print("Failed to send message to Telegram bot: {}\n", .{request.response.status});
    // }
}
