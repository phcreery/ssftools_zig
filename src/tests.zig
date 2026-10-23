//! Root of `zig build test`: pulls in the test blocks of every source file.
//!
//! Test blocks are only collected from the file the test runner is started on,
//! so each module is referenced here explicitly.

test {
    _ = @import("cformat.zig");
    _ = @import("ssftool.zig");
    _ = @import("pfm.zig");
    _ = @import("pfm2specdata.zig");
    _ = @import("main.zig");
}
