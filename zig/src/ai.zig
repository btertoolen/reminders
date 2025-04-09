const std = @import("std");

const time_h = @cImport({
    @cInclude("time.h");
});

const MistralResponse = struct {
    choices: []Choice,

    pub const Choice = struct {
        index: usize,
        message: Message,
        finish_reason: []const u8,
    };

    pub const Message = struct {
        role: []const u8,
        tool_calls: ?[]const u8,
        content: []const u8, // This contains the reminder JSON
    };
};

const ReminderJson = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    repeat_monday: bool = false,
    repeat_tuesday: bool = false,
    repeat_wednesday: bool = false,
    repeat_thursday: bool = false,
    repeat_friday: bool = false,
    repeat_saturday: bool = false,
    repeat_sunday: bool = false,
    no_repeats: bool = false,
    reminder_text: []const u8 = "",

    pub fn format(
        self: ReminderJson,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("pub const Reminder = struct {{ ", .{});
        inline for (std.meta.fields(@TypeOf(self))) |f| {
            try writer.print("{s}: {s}, ", .{ f.name, @typeName(f.type) });
        }
        try writer.writeAll("};");
    }
};

const ReminderJsonList = struct {
    reminders: []ReminderJson,
};

pub const Reminder = struct {
    hour: u8 = 0,
    minute: u8 = 0,
    repeat_monday: bool = false,
    repeat_tuesday: bool = false,
    repeat_wednesday: bool = false,
    repeat_thursday: bool = false,
    repeat_friday: bool = false,
    repeat_saturday: bool = false,
    repeat_sunday: bool = false,
    no_repeats: bool = false,
    reminder_text: std.ArrayList(u8),
    day_sent: u16 = 0, // This value doesnt need to be serialized so its missing from json types

    pub fn create(allocator: std.mem.Allocator) !Reminder {
        return .{ .reminder_text = std.ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Reminder) void {
        self.reminder_text.deinit();
    }

    pub fn fromJsonStr(allocator: std.mem.Allocator, json_str: []const u8) !Reminder {
        // ToDo: replace this with something that doesnt require maintaining 2 reminder structs

        const temp_json = try std.json.parseFromSlice(ReminderJson, allocator, json_str, .{});
        defer temp_json.deinit();

        // Create the final Reminder with ArrayList
        var reminder = try Reminder.create(allocator);

        const temp = temp_json.value;

        reminder.hour = temp.hour;
        reminder.minute = temp.minute;
        reminder.repeat_monday = temp.repeat_monday;
        reminder.repeat_tuesday = temp.repeat_tuesday;
        reminder.repeat_wednesday = temp.repeat_wednesday;
        reminder.repeat_thursday = temp.repeat_thursday;
        reminder.repeat_friday = temp.repeat_friday;
        reminder.repeat_saturday = temp.repeat_saturday;
        reminder.repeat_sunday = temp.repeat_sunday;
        reminder.no_repeats = temp.no_repeats;

        try reminder.reminder_text.appendSlice(temp.reminder_text);

        return reminder;
    }

    pub fn toJsonStr(self: Reminder, allocator: std.mem.Allocator) ![]u8 {
        const reminder_json: ReminderJson = .{ .hour = self.hour, .minute = self.minute, .repeat_monday = self.repeat_monday, .repeat_tuesday = self.repeat_tuesday, .repeat_wednesday = self.repeat_wednesday, .repeat_thursday = self.repeat_thursday, .repeat_friday = self.repeat_friday, .repeat_saturday = self.repeat_saturday, .repeat_sunday = self.repeat_sunday, .no_repeats = self.no_repeats };
        return try std.json.stringifyAlloc(allocator, reminder_json, .{});
    }
};

pub const MistralAI = struct {
    const static_request_content = "The sentence before this one is a request that can be in either english or dutch. Can you turn the request from the sentence before this one into a json message that i can serialize into the following zig struct(Please respond with only the json object, without any formatting. Also dont enclose it in '```'): ";

    api_key: std.ArrayList(u8) = undefined,
    reminders: std.ArrayList(Reminder) = undefined,
    file_storage: std.ArrayList(u8) = undefined,

    pub fn init(self: *MistralAI, allocator: std.mem.Allocator, key: []const u8) !void {
        self.api_key = std.ArrayList(u8).init(allocator);
        try self.api_key.appendSlice(key);

        self.reminders = std.ArrayList(Reminder).init(allocator);

        const home_dir = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home_dir);

        const path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "reminders.json" });
        defer allocator.free(path);

        self.file_storage = std.ArrayList(u8).init(allocator);
        try self.file_storage.appendSlice(path);

        try self.loadReminders(allocator);
    }

    pub fn deinit(self: MistralAI) void {
        self.api_key.deinit();
        self.reminders.deinit();
        self.file_storage.deinit();
    }

    pub fn CreateReminder(self: *MistralAI, allocator: std.mem.Allocator, query: []const u8) !Reminder {
        const reminder: ReminderJson = .{};
        const mistral_query = try std.fmt.allocPrint(allocator, "{s}. {s} {s}. Please make sure the field reminder_text only contains the actions to be taken, and not the time at which to do so. The reminder_text field should just contain a string.", .{ query, static_request_content, reminder });

        const result = try TurnRequestIntoStruct(self, allocator, mistral_query);
        try self.reminders.append(result);
        try self.saveReminders(allocator);
        return result;
    }

    fn loadReminders(self: *MistralAI, allocator: std.mem.Allocator) !void {
        var fs = std.fs.openFileAbsolute(self.file_storage.items, .{ .mode = .read_only }) catch |err| {
            switch (err) {
                std.fs.File.OpenError.FileNotFound => {
                    return;
                },
                else => {
                    return err;
                },
            }
        };
        const file_content = try fs.readToEndAlloc(allocator, 1e9);
        defer allocator.free(file_content);
        const json_list = try std.json.parseFromSlice(ReminderJsonList, allocator, file_content, .{});
        const reminder_list = json_list.value;
        for (reminder_list.reminders) |reminder| {
            var loaded_reminder = try Reminder.create(allocator);
            loaded_reminder.hour = reminder.hour;
            loaded_reminder.minute = reminder.minute;
            loaded_reminder.repeat_monday = reminder.repeat_monday;
            loaded_reminder.repeat_tuesday = reminder.repeat_tuesday;
            loaded_reminder.repeat_wednesday = reminder.repeat_wednesday;
            loaded_reminder.repeat_thursday = reminder.repeat_thursday;
            loaded_reminder.repeat_friday = reminder.repeat_friday;
            loaded_reminder.repeat_saturday = reminder.repeat_saturday;
            loaded_reminder.repeat_sunday = reminder.repeat_sunday;
            loaded_reminder.no_repeats = reminder.no_repeats;
            try loaded_reminder.reminder_text.appendSlice(reminder.reminder_text);
            try self.reminders.append(loaded_reminder);
        }
    }

    fn saveReminders(self: MistralAI, allocator: std.mem.Allocator) !void {
        var fs = try std.fs.createFileAbsolute(self.file_storage.items, .{});
        var reminder_jsons = std.ArrayList(ReminderJson).init(allocator);
        for (self.reminders.items) |reminder| {
            try reminder_jsons.append(.{ .hour = reminder.hour, .minute = reminder.minute, .repeat_monday = reminder.repeat_monday, .repeat_tuesday = reminder.repeat_tuesday, .repeat_wednesday = reminder.repeat_wednesday, .repeat_thursday = reminder.repeat_thursday, .repeat_friday = reminder.repeat_friday, .repeat_saturday = reminder.repeat_saturday, .repeat_sunday = reminder.repeat_sunday, .no_repeats = reminder.no_repeats, .reminder_text = reminder.reminder_text.items });
        }
        const reminder_json_list: ReminderJsonList = .{ .reminders = reminder_jsons.items };
        const file_content = try std.json.stringifyAlloc(allocator, reminder_json_list, .{ .whitespace = .indent_4 });
        defer allocator.free(file_content);

        try fs.writeAll(file_content);
    }

    fn TurnRequestIntoStruct(self: *MistralAI, allocator: std.mem.Allocator, query: []const u8) !Reminder {
        const url = "https://api.mistral.ai/v1/chat/completions";
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key.items});
        defer allocator.free(bearer);

        var response_body = std.ArrayList(u8).init(allocator);
        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Authorization", .value = bearer },
        };
        const request_body = try std.fmt.allocPrint(allocator, "{{ \"model\": \"mistral-large-latest\", \"messages\": [{{\"role\": \"user\",\"content\": \"{s}\"}}]}}", .{query});
        defer allocator.free(request_body);

        const response = try client.fetch(.{
            .method = .POST,
            .location = .{ .url = url },
            .extra_headers = headers, //put these here instead of .headers
            .response_storage = .{ .dynamic = &response_body }, // this allows us to get a response of unknown size
            .payload = request_body,
        });

        std.debug.print("Response Status: {d}\n Response Body:{s}\n", .{ response.status, response_body.items });
        const json_response = try std.json.parseFromSlice(MistralResponse, allocator, response_body.items, .{
            .ignore_unknown_fields = true, // Allow unknown fields in the response
        });
        defer json_response.deinit();

        // const json_reminder = try std.json.parseFromSlice(Reminder, allocator, json_response.value.choices[0].message.content, .{});
        return Reminder.fromJsonStr(allocator, json_response.value.choices[0].message.content);
        // defer json_reminder.deinit();
        // return allocator.dupe(Reminder, json_reminder.value);
    }

    pub fn GetRemindersToSend(self: *MistralAI, allocator: std.mem.Allocator) !std.ArrayList(std.ArrayList(u8)) {
        // const secs_since_epoch = std.time.timestamp();
        // const calendar_time = std.time.calendarFromEpoch(now);
        // const day_of_year = std.time.dayOfYear(calendar_time);
        // std.time.epoch;
        // const hours_now = calendar_time.hour;
        // const minutes_now = calendar_time.minute;

        // Allocate memory for the time structure
        var timeinfo: time_h.tm = undefined;

        // Get the current time
        const time_t_value = time_h.time(null);
        if (time_t_value == 0) {
            std.debug.print("Failed to get current time\n", .{});
            return error.FailedToGetTime;
        }

        // Convert the time to a tm structure
        const tm_ptr = time_h.localtime(&time_t_value);
        if (tm_ptr == null) {
            std.debug.print("Failed to convert time to local time\n", .{});
            return error.FailedToGetTime;
        }
        timeinfo = tm_ptr.*;

        // Extract the desired time components
        const hours_now: u32 = @intCast(timeinfo.tm_hour);
        const minutes_now: u32 = @intCast(timeinfo.tm_min);
        const day_of_year: u32 = @intCast(timeinfo.tm_yday + 1); // tm_yday is 0-based
        const weekday: u32 = @intCast(timeinfo.tm_wday); // 0 is Sunday, 1 is Monday, ..., 6 is Saturday

        var result = std.ArrayList(std.ArrayList(u8)).init(allocator);
        var index: i64 = -1;
        var indexes_to_remove = std.ArrayList(i64).init(allocator);

        for (self.reminders.items) |*reminder| {
            index = index + 1;
            // skip if reminder has already been sent today
            if (reminder.day_sent != 0 and reminder.day_sent != day_of_year) {
                continue;
            }

            if (reminder.hour != hours_now or reminder.minute != minutes_now) {
                continue;
            }

            switch (weekday) {
                0 => if (!reminder.repeat_sunday and reminder.day_sent != 0) continue, // Sunday
                1 => if (!reminder.repeat_monday and reminder.day_sent != 0) continue, // Monday
                2 => if (!reminder.repeat_tuesday and reminder.day_sent != 0) continue, // Tuesday
                3 => if (!reminder.repeat_wednesday and reminder.day_sent != 0) continue, // Wednesday
                4 => if (!reminder.repeat_thursday and reminder.day_sent != 0) continue, // Thursday
                5 => if (!reminder.repeat_friday and reminder.day_sent != 0) continue, // Friday
                6 => if (!reminder.repeat_saturday and reminder.day_sent != 0) continue, // Saturday
                else => unreachable,
            }

            if (reminder.no_repeats) {
                try indexes_to_remove.append(index);
            }
            reminder.day_sent = @intCast(day_of_year);
            std.debug.print("Running reminder {s} with {d}:{d} at {d}:{d}\n", .{ reminder.reminder_text.items, reminder.hour, reminder.minute, hours_now, minutes_now });
            var reminder_to_send = std.ArrayList(u8).init(allocator);
            try reminder_to_send.appendSlice(reminder.reminder_text.items);
            try result.append(reminder_to_send);
        }

        var decrement_counter: i64 = 0;
        for (indexes_to_remove.items) |idx| {
            _ = self.reminders.orderedRemove(@intCast(idx - decrement_counter));
            decrement_counter = decrement_counter + 1;
        }
        try self.saveReminders(allocator);
        return result;
    }
};
