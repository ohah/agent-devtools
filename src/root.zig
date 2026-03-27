pub const websocket = @import("websocket.zig");
pub const cdp = @import("cdp.zig");
pub const chrome = @import("chrome.zig");
pub const network = @import("network.zig");

test {
    _ = websocket;
    _ = cdp;
    _ = chrome;
    _ = network;
}
