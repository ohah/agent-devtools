pub const websocket = @import("websocket.zig");
pub const cdp = @import("cdp.zig");
pub const chrome = @import("chrome.zig");

test {
    _ = websocket;
    _ = cdp;
    _ = chrome;
}
