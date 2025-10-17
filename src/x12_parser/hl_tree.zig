const std = @import("std");
const testing = std.testing;
const x12_parser = @import("x12_parser.zig");

/// A node in the HL (Hierarchy Level) tree
pub const HLNode = struct {
    /// HL ID (HL01) - unique identifier for this level
    id: []const u8,

    /// Parent HL ID (HL02) - empty string if root
    parent_id: []const u8,

    /// Level code (HL03) - e.g., "20" (billing provider), "22" (subscriber), "23" (patient)
    level_code: []const u8,

    /// Has children flag (HL04) - "0" or "1"
    has_children: bool,

    /// Index of the HL segment in the document
    hl_segment_index: usize,

    /// Start index of segments belonging to this HL (inclusive)
    segment_start: usize,

    /// End index of segments belonging to this HL (exclusive)
    /// This is the index of the next HL segment or end of document
    segment_end: usize,

    /// Child nodes
    children: []HLNode,

    /// Allocator for cleanup
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HLNode) void {
        for (self.children) |*child| {
            child.deinit();
        }
        self.allocator.free(self.children);
    }

    /// Get all segments that belong to this HL node
    pub fn getSegments(self: HLNode, doc: x12_parser.X12Document) ?[]x12_parser.Segment {
        return doc.getSegmentRange(self.segment_start, self.segment_end);
    }

    /// Find a child node by HL ID
    pub fn findChild(self: HLNode, id: []const u8) ?*const HLNode {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.id, id)) {
                return child;
            }
        }
        return null;
    }

    /// Count total descendants (recursive)
    pub fn countDescendants(self: HLNode) usize {
        var count: usize = self.children.len;
        for (self.children) |child| {
            count += child.countDescendants();
        }
        return count;
    }
};

/// HL Tree representing the hierarchical structure of an X12 document
pub const HLTree = struct {
    /// Root nodes (typically one, but could be multiple in some cases)
    roots: []HLNode,

    /// Allocator for cleanup
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HLTree) void {
        for (self.roots) |*root| {
            root.deinit();
        }
        self.allocator.free(self.roots);
    }

    /// Find a node by HL ID (searches entire tree)
    pub fn findNode(self: HLTree, id: []const u8) ?*const HLNode {
        for (self.roots) |*root| {
            if (std.mem.eql(u8, root.id, id)) {
                return root;
            }
            if (findNodeRecursive(root, id)) |node| {
                return node;
            }
        }
        return null;
    }

    /// Count total nodes in tree
    pub fn countNodes(self: HLTree) usize {
        var count: usize = self.roots.len;
        for (self.roots) |root| {
            count += root.countDescendants();
        }
        return count;
    }

    /// Get all nodes at a specific level code (e.g., all "22" subscribers)
    pub fn getNodesByLevel(self: HLTree, allocator: std.mem.Allocator, level_code: []const u8) ![]HLNode {
        var matches = std.ArrayList(HLNode){};
        errdefer matches.deinit(allocator);

        for (self.roots) |root| {
            try collectNodesByLevel(&matches, allocator, &root, level_code);
        }

        return matches.toOwnedSlice(allocator);
    }
};

/// Helper function to recursively find a node
fn findNodeRecursive(node: *const HLNode, id: []const u8) ?*const HLNode {
    for (node.children) |*child| {
        if (std.mem.eql(u8, child.id, id)) {
            return child;
        }
        if (findNodeRecursive(child, id)) |found| {
            return found;
        }
    }
    return null;
}

/// Helper function to collect nodes by level code
fn collectNodesByLevel(
    list: *std.ArrayList(HLNode),
    allocator: std.mem.Allocator,
    node: *const HLNode,
    level_code: []const u8,
) !void {
    if (std.mem.eql(u8, node.level_code, level_code)) {
        try list.append(allocator, node.*);
    }
    for (node.children) |*child| {
        try collectNodesByLevel(list, allocator, child, level_code);
    }
}

/// Build HL tree from a parsed X12 document
pub fn buildTree(allocator: std.mem.Allocator, doc: x12_parser.X12Document) !HLTree {
    // Step 1: Find all HL segments
    const hl_segments = try doc.findAllSegments(allocator, "HL");
    defer allocator.free(hl_segments);

    if (hl_segments.len == 0) {
        return error.NoHLSegments;
    }

    // Step 2: Build a map of HL ID -> node info
    var node_map = std.StringHashMap(HLNodeBuilder).init(allocator);
    defer {
        var iter = node_map.valueIterator();
        while (iter.next()) |builder| {
            builder.deinit();
        }
        node_map.deinit();
    }

    // Parse all HL segments and create node builders
    for (hl_segments, 0..) |hl, i| {
        const id = hl.getElement(1) orelse return error.MissingHLID;
        const parent_id = hl.getElement(2) orelse "";
        const level_code = hl.getElement(3) orelse return error.MissingLevelCode;
        const has_children_str = hl.getElement(4) orelse "0";
        const has_children = std.mem.eql(u8, has_children_str, "1");

        // Calculate segment range for this HL
        const segment_start = hl.index;
        const segment_end = if (i + 1 < hl_segments.len)
            hl_segments[i + 1].index
        else
            doc.segments.len;

        const builder = HLNodeBuilder{
            .id = id,
            .parent_id = parent_id,
            .level_code = level_code,
            .has_children = has_children,
            .hl_segment_index = hl.index,
            .segment_start = segment_start,
            .segment_end = segment_end,
            .children = std.ArrayList([]const u8){},
            .allocator = allocator,
        };

        try node_map.put(id, builder);
    }

    // Step 3: Build parent-child relationships
    var iter = node_map.iterator();
    while (iter.next()) |entry| {
        const builder = entry.value_ptr;
        if (builder.parent_id.len > 0) {
            if (node_map.getPtr(builder.parent_id)) |parent_builder| {
                try parent_builder.children.append(allocator, builder.id);
            } else {
                return error.ParentNotFound;
            }
        }
    }

    // Step 4: Build the actual tree starting from roots
    var roots = std.ArrayList(HLNode){};
    errdefer {
        for (roots.items) |*root| {
            root.deinit();
        }
        roots.deinit(allocator);
    }

    // Find root nodes (those with no parent)
    var root_iter = node_map.iterator();
    while (root_iter.next()) |entry| {
        const builder = entry.value_ptr;
        if (builder.parent_id.len == 0) {
            const root_node = try buildNodeRecursive(allocator, &node_map, builder.id);
            try roots.append(allocator, root_node);
        }
    }

    if (roots.items.len == 0) {
        return error.NoRootNodes;
    }

    return HLTree{
        .roots = try roots.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Temporary builder structure for constructing nodes
const HLNodeBuilder = struct {
    id: []const u8,
    parent_id: []const u8,
    level_code: []const u8,
    has_children: bool,
    hl_segment_index: usize,
    segment_start: usize,
    segment_end: usize,
    children: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    fn deinit(self: *HLNodeBuilder) void {
        self.children.deinit(self.allocator);
    }
};

/// Recursively build HLNode from builder
fn buildNodeRecursive(
    allocator: std.mem.Allocator,
    node_map: *std.StringHashMap(HLNodeBuilder),
    id: []const u8,
) !HLNode {
    const builder = node_map.get(id) orelse return error.NodeNotFound;

    var children = std.ArrayList(HLNode){};
    errdefer {
        for (children.items) |*child| {
            child.deinit();
        }
        children.deinit(allocator);
    }

    for (builder.children.items) |child_id| {
        const child_node = try buildNodeRecursive(allocator, node_map, child_id);
        try children.append(allocator, child_node);
    }

    return HLNode{
        .id = builder.id,
        .parent_id = builder.parent_id,
        .level_code = builder.level_code,
        .has_children = builder.has_children,
        .hl_segment_index = builder.hl_segment_index,
        .segment_start = builder.segment_start,
        .segment_end = builder.segment_end,
        .children = try children.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ============================================================================
// UNIT TESTS
// ============================================================================

test "build simple HL tree with one root" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20210101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*BATCH123*20210101*1200*CH~
        \\HL*1**20*1~
        \\NM1*85*2*PROVIDER*NAME****XX*1234567890~
        \\SE*6*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.roots.len);
    try testing.expectEqualStrings("1", tree.roots[0].id);
    try testing.expectEqualStrings("", tree.roots[0].parent_id);
    try testing.expectEqualStrings("20", tree.roots[0].level_code);
    try testing.expectEqual(true, tree.roots[0].has_children);
    try testing.expectEqual(@as(usize, 0), tree.roots[0].children.len);
}

test "build HL tree with parent-child relationship" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20210101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\HL*1**20*1~
        \\NM1*85*2*PROVIDER~
        \\HL*2*1*22*0~
        \\NM1*IL*1*SUBSCRIBER~
        \\SE*7*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.roots.len);

    const root = tree.roots[0];
    try testing.expectEqualStrings("1", root.id);
    try testing.expectEqualStrings("20", root.level_code);
    try testing.expectEqual(@as(usize, 1), root.children.len);

    const child = root.children[0];
    try testing.expectEqualStrings("2", child.id);
    try testing.expectEqualStrings("1", child.parent_id);
    try testing.expectEqualStrings("22", child.level_code);
    try testing.expectEqual(false, child.has_children);
}

test "build HL tree with multiple children" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\ST*837*0001~
        \\HL*1**20*1~
        \\NM1*85*2*PROVIDER~
        \\HL*2*1*22*0~
        \\NM1*IL*1*SUBSCRIBER1~
        \\HL*3*1*22*0~
        \\NM1*IL*1*SUBSCRIBER2~
        \\SE*8*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    const root = tree.roots[0];
    try testing.expectEqual(@as(usize, 2), root.children.len);
    try testing.expectEqualStrings("2", root.children[0].id);
    try testing.expectEqualStrings("3", root.children[1].id);
}

test "segment ranges calculated correctly" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\ST*837*0001~
        \\HL*1**20*1~
        \\NM1*85*2*PROVIDER~
        \\REF*EI*123456789~
        \\HL*2*1*22*0~
        \\NM1*IL*1*SUBSCRIBER~
        \\DMG*D8*19800101~
        \\SE*8*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    const root = tree.roots[0];
    // Root HL is at index 2, next HL is at index 5
    try testing.expectEqual(@as(usize, 2), root.segment_start);
    try testing.expectEqual(@as(usize, 5), root.segment_end);

    // Child segments
    const segments = root.getSegments(doc).?;
    try testing.expectEqual(@as(usize, 3), segments.len);
    try testing.expectEqualStrings("HL", segments[0].id);
    try testing.expectEqualStrings("NM1", segments[1].id);
    try testing.expectEqualStrings("REF", segments[2].id);
}

test "find node by ID" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\ST*837*0001~
        \\HL*1**20*1~
        \\HL*2*1*22*1~
        \\HL*3*2*23*0~
        \\SE*5*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    const node = tree.findNode("3");
    try testing.expect(node != null);
    try testing.expectEqualStrings("3", node.?.id);
    try testing.expectEqualStrings("2", node.?.parent_id);
    try testing.expectEqualStrings("23", node.?.level_code);
}

test "count nodes and descendants" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\ST*837*0001~
        \\HL*1**20*1~
        \\HL*2*1*22*1~
        \\HL*3*2*23*0~
        \\HL*4*1*22*0~
        \\SE*6*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 4), tree.countNodes());

    const root = tree.roots[0];
    try testing.expectEqual(@as(usize, 3), root.countDescendants());
}

test "get nodes by level code" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\ST*837*0001~
        \\HL*1**20*1~
        \\HL*2*1*22*0~
        \\HL*3*1*22*0~
        \\HL*4*1*22*0~
        \\SE*6*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    var tree = try buildTree(allocator, doc);
    defer tree.deinit();

    const subscribers = try tree.getNodesByLevel(allocator, "22");
    defer allocator.free(subscribers);

    try testing.expectEqual(@as(usize, 3), subscribers.len);
}

test "error on missing HL segments" {
    const allocator = testing.allocator;

    const x12_content =
        \\ISA*00*          *00*          *ZZ*SUBMITTER      *ZZ*RECEIVER       *210101*1200*^*00501*000000001*0*P*:~
        \\ST*837*0001~
        \\BHT*0019*00*BATCH123~
        \\SE*3*0001~
    ;

    var doc = try x12_parser.parse(allocator, x12_content);
    defer doc.deinit();

    const result = buildTree(allocator, doc);
    try testing.expectError(error.NoHLSegments, result);
}
