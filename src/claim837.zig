const std = @import("std");
const Allocator = std.mem.Allocator;
const x12 = @import("parser.zig");
const utils = @import("utils.zig");

// Globals for shared library
var ARENA = std.heap.ArenaAllocator.init(std.heap.c_allocator);
const ALLOCATOR = ARENA.allocator();
var BUFFER_MAP = std.AutoArrayHashMap(usize, []const u8).init(ALLOCATOR);
//Exported C function to parse an 837 document
export fn parse837(input: [*c]const u8, sz: c_int) callconv(.C) [*c]const u8 {
    //Parse the X12 document
    var document = x12.X12Document.init(ALLOCATOR);
    defer document.deinit();
    document.parse(input[0..@as(usize, @intCast(sz))]) catch |err| {
        std.log.debug("Error parsing X12 document", .{});
        return @ptrCast(std.fmt.allocPrint(ALLOCATOR, "Error parsing X12 document: {s}", .{@errorName(err)}) catch unreachable);
    };

    //Parse the 837 claim
    var claim = Claim837.init(ALLOCATOR);
    defer claim.deinit();
    claim.parse(&document) catch |err| {
        std.log.debug("Error parsing 837 claim", .{});
        return @ptrCast(std.fmt.allocPrint(ALLOCATOR, "Error parsing 837 claim: {s}", .{@errorName(err)}) catch unreachable);
    };

    const j = std.json.stringifyAlloc(ALLOCATOR, claim, .{}) catch |err| {
        return @ptrCast(std.fmt.allocPrint(ALLOCATOR, "Error serializing JSON: {s}", .{@errorName(err)}) catch unreachable);
    };
    BUFFER_MAP.put(@intFromPtr(j.ptr), j) catch unreachable;
    return @ptrCast(j);
}

export fn getBufferSz(ptr: [*c]const u8) callconv(.C) c_int {
    const int = @intFromPtr(ptr);
    const j = BUFFER_MAP.get(int) orelse return 0;
    return @intCast(j.len);
}

export fn free837(ptr: [*c]const u8) callconv(.C) void {
    const int = @intFromPtr(ptr);
    const j = BUFFER_MAP.get(int) orelse return;
    ALLOCATOR.free(j);
}

const DxTypes = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "ABK", "Principal" },
    .{ "ABF", "Secondary" },
    .{ "ABJ", "Admitting" },
    .{ "ABN", "External Cause of Injury" },
    .{ "APR", "Reason For Visit" },
});

const PxTypes = std.StaticStringMap([]const u8).initComptime(&.{
    .{ "BBR", "Principal Procedure" },
    .{ "BBQ", "Secondary Procedure" },
});

const HiTypes = enum {
    BG, //Condition Codes
    BH, //Occurrence Codes
    BI, //Occurrence Span Codes
    BE, //Value Codes
};

/// Represents an 837 Healthcare Claim - can be Professional (837P), Institutional (837I), or Dental (837D)
pub const Claim837 = struct {
    // Transaction metadata
    transaction_type: TransactionType = .unknown,
    transaction_control_number: []const u8 = "",

    // Trading partner info
    sender_id: []const u8 = "",
    receiver_id: []const u8 = "",

    // Billing provider info
    billing_provider: BillingProvider = .{},

    // Subscriber loops
    subscriber_loops: std.ArrayList(SubscriberLoop),

    allocator: Allocator,

    pub const TransactionType = enum {
        unknown,
        professional, // 837P
        institutional, // 837I
        dental, // 837D
    };

    pub fn init(allocator: Allocator) Claim837 {
        return .{
            .subscriber_loops = std.ArrayList(SubscriberLoop).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Claim837) void {
        for (0..self.subscriber_loops.items.len) |loop| {
            self.subscriber_loops.items[loop].deinit();
        }
        self.subscriber_loops.deinit();
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }

    /// Parse an X12 document into an 837 claim
    pub fn parse(self: *Claim837, document: *const x12.X12Document) !void {
        // Find ST segment to determine transaction type
        const st_segment = document.getSegment("ST") orelse return x12.X12Error.MissingSegment;
        if (st_segment.elements.items.len < 2) return x12.X12Error.InvalidSegment;

        const transaction_id = st_segment.elements.items[0].value;
        self.transaction_control_number = if (st_segment.elements.items.len > 2) st_segment.elements.items[2].value else "";

        // Determine transaction type
        if (!std.mem.eql(u8, transaction_id, "837")) {
            return x12.X12Error.InvalidTransactionType;
        }
        //Get the ST segment value
        if (st_segment.elements.items.len > 2) {
            if (std.mem.containsAtLeast(u8, st_segment.elements.items[2].value, 1, "005010X222")) {
                self.transaction_type = .professional;
            } else if (std.mem.containsAtLeast(u8, st_segment.elements.items[2].value, 1, "005010X223")) {
                self.transaction_type = .institutional;
            } else if (std.mem.containsAtLeast(u8, st_segment.elements.items[2].value, 1, "005010X224")) {
                self.transaction_type = .dental;
            } else {
                self.transaction_type = .unknown;
            }
        }

        // Parse ISA segment for sender/receiver IDs
        const isa_segment = document.getSegment("ISA") orelse return x12.X12Error.MissingSegment;
        if (isa_segment.elements.items.len < 13) return x12.X12Error.InvalidSegment;

        //Sender is in ISA06, receiver is in ISA08
        //Strip trailing whitespace
        var stop: usize = isa_segment.elements.items[5].value.len;
        while (stop > 0 and isa_segment.elements.items[5].value[stop - 1] == ' ') {
            stop -= 1;
        }
        self.sender_id = isa_segment.elements.items[5].value[0..stop];

        stop = isa_segment.elements.items[7].value.len;
        while (stop > 0 and isa_segment.elements.items[7].value[stop - 1] == ' ') {
            stop -= 1;
        }
        self.receiver_id = isa_segment.elements.items[7].value[0..stop];

        // Start processing hierarchical loops
        try self.parseHierarchicalStructure(document);
    }

    fn parseHierarchicalStructure(self: *Claim837, document: *const x12.X12Document) !void {
        var hl_segments = try document.getSegments("HL", self.allocator);
        defer hl_segments.deinit();
        var current_info_source_id: []const u8 = "";
        var current_subscriber_id: []const u8 = "";
        var current_patient_id: []const u8 = "";
        var found_patient_hl = false;

        // First pass - identify all hierarchical levels
        for (hl_segments.items) |hl_segment| {
            if (hl_segment.elements.items.len < 4) continue;
            const hl_id = hl_segment.elements.items[0].value;
            //const hl_parent_id = hl_segment.elements.items[1].value;
            const hl_level_code = hl_segment.elements.items[2].value;
            // Information Source - 2000A loop with HL03=20
            if (std.mem.eql(u8, hl_level_code, "20")) {
                current_info_source_id = hl_id;
                try self.parseBillingProvider(document);
            }
            // Subscriber - 2000B loop with HL03=22
            else if (std.mem.eql(u8, hl_level_code, "22")) {
                current_subscriber_id = hl_id;
                try self.parseSubscriber(document, hl_segment);
            }
            // Patient - 2000C loop with HL03=23
            else if (std.mem.eql(u8, hl_level_code, "23")) {
                found_patient_hl = true;
                current_patient_id = hl_id;
                try self.parsePatient(document, current_subscriber_id);
            }
        }

        // If no patient HL segment was found, check if any subscribers have relationship code "18" (self)
        // and create patient info from subscriber in those cases
        if (!found_patient_hl) {
            for (self.subscriber_loops.items) |*subscriber_loop| {
                if (std.mem.eql(u8, subscriber_loop.sbr_individual_relationship, "18")) {
                    try self.createPatientFromSubscriber(document, subscriber_loop);
                }
            }
        }

        // Second pass - process claims
        try self.parseClaims(document);
    }

    // New function to create patient info from subscriber when they are the same person
    fn createPatientFromSubscriber(self: *Claim837, document: *const x12.X12Document, subscriber_loop: *SubscriberLoop) !void {
        var patient_info = PatientInfo.init(self.allocator);
        // Copy subscriber information to patient
        patient_info.entity_type = subscriber_loop.subscriber.entity_type;
        patient_info.last_name = subscriber_loop.subscriber.last_name;
        patient_info.first_name = subscriber_loop.subscriber.first_name;

        // Parse DMG segment for patient demographics
        if (document.getSegment("DMG")) |dmg_segment| {
            if (dmg_segment.elements.items.len > 1) {
                patient_info.birth_date = dmg_segment.elements.items[1].value;
            }
            if (dmg_segment.elements.items.len > 2) {
                patient_info.gender = dmg_segment.elements.items[2].value;
            }
        }

        try subscriber_loop.patients.append(patient_info);
    }

    fn parseBillingProvider(self: *Claim837, document: *const x12.X12Document) !void {
        // Find billing provider segments - typically NM1*85 segment
        var nm1_segments = try document.getSegments("NM1", self.allocator);
        defer nm1_segments.deinit();

        for (nm1_segments.items) |nm1_segment| {
            if (nm1_segment.elements.items.len < 3) continue;
            // NM1*85 is the billing provider
            if (std.mem.eql(u8, nm1_segment.elements.items[0].value, "85")) {
                self.billing_provider.entity_type = if (std.mem.eql(u8, nm1_segment.elements.items[1].value, "1"))
                    .person
                else
                    .organization;

                if (nm1_segment.elements.items.len > 3) {
                    self.billing_provider.last_name = nm1_segment.elements.items[2].value;
                }

                if (nm1_segment.elements.items.len > 4) {
                    self.billing_provider.first_name = nm1_segment.elements.items[3].value;
                }

                if (nm1_segment.elements.items.len > 8) {
                    self.billing_provider.id_qualifier = nm1_segment.elements.items[7].value;
                    self.billing_provider.id = nm1_segment.elements.items[8].value;
                }

                break;
            }
        }

        // Parse N3 and N4 segments for address info
        if (document.getSegment("N3")) |n3_segment| {
            if (n3_segment.elements.items.len > 0) {
                self.billing_provider.address1 = n3_segment.elements.items[0].value;
            }
            if (n3_segment.elements.items.len > 1) {
                self.billing_provider.address2 = n3_segment.elements.items[1].value;
            }
        }

        if (document.getSegment("N4")) |n4_segment| {
            if (n4_segment.elements.items.len > 0) {
                self.billing_provider.city = n4_segment.elements.items[0].value;
            }
            if (n4_segment.elements.items.len > 1) {
                self.billing_provider.state = n4_segment.elements.items[1].value;
            }
            if (n4_segment.elements.items.len > 2) {
                self.billing_provider.zip = n4_segment.elements.items[2].value;
            }
        }
    }

    fn parseSubscriber(self: *Claim837, document: *const x12.X12Document, hl_segment: *const x12.Segment) !void {
        var subscriber_loop = SubscriberLoop.init(self.allocator);
        errdefer subscriber_loop.deinit();

        // Parse HL segment details
        subscriber_loop.hl_id = hl_segment.elements.items[0].value;

        // Parse subscriber demographics from NM1*IL segment
        var nm1_segments = try document.getSegments("NM1", self.allocator);
        defer nm1_segments.deinit();

        for (nm1_segments.items) |nm1_segment| {
            if (nm1_segment.elements.items.len < 3) continue;

            // NM1*IL is the subscriber
            if (std.mem.eql(u8, nm1_segment.elements.items[0].value, "IL")) {
                subscriber_loop.subscriber.entity_type = if (std.mem.eql(u8, nm1_segment.elements.items[1].value, "1"))
                    .person
                else
                    .organization;

                if (nm1_segment.elements.items.len > 3) {
                    subscriber_loop.subscriber.last_name = nm1_segment.elements.items[2].value;
                }

                if (nm1_segment.elements.items.len > 4) {
                    subscriber_loop.subscriber.first_name = nm1_segment.elements.items[3].value;
                }

                if (nm1_segment.elements.items.len > 8) {
                    subscriber_loop.subscriber.id_qualifier = nm1_segment.elements.items[7].value;
                    subscriber_loop.subscriber.id = nm1_segment.elements.items[8].value;
                }

                break;
            }
        }

        // Parse insurance info from SBR segment
        if (document.getSegment("SBR")) |sbr_segment| {
            if (sbr_segment.elements.items.len > 0) {
                subscriber_loop.sbr_payer_responsibility = sbr_segment.elements.items[0].value;
            }
            if (sbr_segment.elements.items.len > 1) {
                subscriber_loop.sbr_individual_relationship = sbr_segment.elements.items[1].value;
            }
            if (sbr_segment.elements.items.len > 2) {
                subscriber_loop.sbr_reference_id = sbr_segment.elements.items[2].value;
            }
            if (sbr_segment.elements.items.len > 8) {
                subscriber_loop.sbr_claim_filing_code = sbr_segment.elements.items[8].value;
            }
        }

        try self.subscriber_loops.append(subscriber_loop);
    }

    fn parsePatient(self: *Claim837, document: *const x12.X12Document, subscriber_id: []const u8) !void {
        // Find the subscriber loop this patient belongs to
        var subscriber_loop: ?*SubscriberLoop = null;
        for (self.subscriber_loops.items) |*loop| {
            if (std.mem.eql(u8, loop.hl_id, subscriber_id)) {
                subscriber_loop = loop;
                break;
            }
        }

        if (subscriber_loop == null) return;

        var patient_info = PatientInfo.init(self.allocator);

        // Parse patient demographics from NM1*QC segment
        var nm1_segments = try document.getSegments("NM1", self.allocator);
        defer nm1_segments.deinit();

        for (nm1_segments.items) |nm1_segment| {
            if (nm1_segment.elements.items.len < 3) continue;
            // NM1*QC is the patient
            if (std.mem.eql(u8, nm1_segment.elements.items[1].value, "QC")) {
                patient_info.entity_type = if (std.mem.eql(u8, nm1_segment.elements.items[2].value, "1"))
                    .person
                else
                    .organization;

                if (nm1_segment.elements.items.len > 3) {
                    patient_info.last_name = nm1_segment.elements.items[3].value;
                }

                if (nm1_segment.elements.items.len > 4) {
                    patient_info.first_name = nm1_segment.elements.items[4].value;
                }

                break;
            }
        }

        // Parse DMG segment for patient demographics
        if (document.getSegment("DMG")) |dmg_segment| {
            if (dmg_segment.elements.items.len > 2) {
                patient_info.birth_date = dmg_segment.elements.items[2].value;
            }
            if (dmg_segment.elements.items.len > 3) {
                patient_info.gender = dmg_segment.elements.items[3].value;
            }
        }

        try subscriber_loop.?.patients.append(patient_info);
    }

    fn parseClaims(self: *Claim837, document: *const x12.X12Document) !void {
        // Get all segments to work with segment boundaries
        const all_segments = &document.segments;
        var clm_indices = std.ArrayList(usize).init(self.allocator);
        defer clm_indices.deinit();

        // First pass - identify all CLM segments and their positions
        for (all_segments.items, 0..) |segment, idx| {
            if (std.mem.eql(u8, segment.id, "CLM")) {
                try clm_indices.append(idx);
            }
        }

        // Second pass - process each claim with its associated segments
        for (clm_indices.items, 0..) |clm_idx, i| {
            const clm_segment = all_segments.items[clm_idx];
            if (clm_segment.elements.items.len < 2) continue;

            var claim = Claim.init(self.allocator);
            errdefer claim.deinit();

            // Parse basic claim information
            claim.claim_id = clm_segment.elements.items[0].value;
            claim.total_charges = clm_segment.elements.items[1].value;

            // Find place of service
            if (clm_segment.elements.items.len > 4) {
                const place_info = clm_segment.elements.items[4];
                if (place_info.components.items.len > 0) {
                    claim.place_of_service = place_info.components.items[0];
                }
            }

            // Determine the end boundary of this claim
            const end_idx = if (i < clm_indices.items.len - 1)
                clm_indices.items[i + 1]
            else
                all_segments.items.len;

            // Process only segments that belong to this claim (between current CLM and next CLM or end)
            const claim_segments = all_segments.items[clm_idx..end_idx];

            // Process HI segments for this claim only
            for (claim_segments) |segment| {
                if (std.mem.eql(u8, segment.id, "HI")) {
                    // Process all elements in the HI segment
                    for (segment.elements.items) |element| {
                        if (element.components.items.len >= 2) {
                            const qualifier = element.components.items[0];
                            //Process Diagnosis Codes
                            if (DxTypes.getIndex(qualifier) != null) {
                                var diag = DiagnosisCode.init();
                                diag.qualifier = element.components.items[0];
                                // Get diagnosis code
                                diag.code = element.components.items[1];
                                if (element.components.items.len > 4) {
                                    diag.poa = element.components.items[8];
                                }
                                try claim.diagnosis_codes.append(diag);
                            } else if (PxTypes.getIndex(qualifier) != null) { //Process ICD Procedure Codes
                                var proc = ProcedureCode.init();
                                proc.qualifier = element.components.items[0];
                                // Get procedure code
                                proc.code = element.components.items[1];
                                try claim.procedure_codes.append(proc);
                            } else { //Process  all other Health Information Codes
                                const hi_type = std.meta.stringToEnum(HiTypes, qualifier) orelse continue;
                                try claim.processHiType(&element, hi_type);
                            }
                        }
                    }
                }
            }

            // Parse service lines - also scoped to this claim
            try self.parseServiceLinesForClaim(claim_segments, &claim);

            // Find the correct subscriber loop for this claim
            // In a real implementation, we would identify the correct subscriber by matching
            // patient/subscriber identifiers to the claim
            if (self.subscriber_loops.items.len > 0) {
                try self.subscriber_loops.items[0].claims.append(claim);
            }
        }
    }

    // New function to parse service lines for a specific claim
    fn parseServiceLinesForClaim(self: *Claim837, segments: []x12.Segment, claim: *Claim) !void {
        // Find LX segments and their associated service line data
        var current_lx_idx: ?usize = null;

        for (segments, 0..) |segment, idx| {
            if (std.mem.eql(u8, segment.id, "LX")) {
                // Found a new LX segment
                if (current_lx_idx != null) {
                    // Process previous service line
                    try self.processServiceLine(segments[current_lx_idx.?..idx], claim);
                }

                current_lx_idx = idx;
            }
        }

        // Process the last service line if one exists
        if (current_lx_idx != null) {
            try self.processServiceLine(segments[current_lx_idx.?..], claim);
        }
    }

    fn processServiceLine(self: *Claim837, segments: []x12.Segment, claim: *Claim) !void {
        // First segment should be LX
        if (segments.len == 0 or !std.mem.eql(u8, segments[0].id, "LX")) {
            return;
        }

        var service_line = ServiceLine.init(self.allocator);
        errdefer service_line.deinit();

        // Get line number from LX segment
        service_line.line_number = segments[0].elements.items[0].value;

        // Find the SV1 or SV2 segment for this service line
        for (segments) |segment| {
            if (std.mem.eql(u8, segment.id, "SV1")) {
                // For SV1 (Professional), procedure code is in element 0
                // Parse procedure code
                if (segment.elements.items.len > 0) {
                    if (segment.elements.items[0].components.items.len > 1) {
                        service_line.procedure_type = segment.elements.items[0].components.items[0];
                        service_line.procedure_code = segment.elements.items[0].components.items[1];
                    }
                    if (segment.elements.items[0].components.items.len > 2) {
                        var mod_idx: usize = 2;
                        while (mod_idx < segment.elements.items[0].components.items.len and mod_idx <= 5) {
                            if (segment.elements.items[0].components.items[mod_idx].len > 0) {
                                try service_line.modifiers.append(segment.elements.items[0].components.items[mod_idx]);
                            }
                            mod_idx += 1;
                        }
                    }
                }
                // Parse charge amount
                if (segment.elements.items.len > 1) {
                    service_line.charge_amount = segment.elements.items[1].value;
                }

                // Parse units - note this is the 4th element (index 3)
                if (segment.elements.items.len > 3) {
                    service_line.units = segment.elements.items[3].value;
                }

                break; // Only use the first SV1 segment for this service line
            } else if (std.mem.eql(u8, segment.id, "SV2")) {
                // For SV2 (Institutional), procedure code is in element 1
                // Parse procedure code
                service_line.revenue_code = segment.elements.items[0].value;
                if (segment.elements.items.len > 1) {
                    if (segment.elements.items[1].components.items.len > 1) {
                        service_line.procedure_type = segment.elements.items[1].components.items[0];
                        service_line.procedure_code = segment.elements.items[1].components.items[1];
                    }
                    if (segment.elements.items[0].components.items.len > 2) {
                        var mod_idx: usize = 2;
                        while (mod_idx < segment.elements.items[0].components.items.len and mod_idx <= 5) {
                            if (segment.elements.items[0].components.items[mod_idx].len > 0) {
                                try service_line.modifiers.append(segment.elements.items[0].components.items[mod_idx]);
                            }
                            mod_idx += 1;
                        }
                    }
                }

                // Parse charge amount
                if (segment.elements.items.len > 2) {
                    service_line.charge_amount = segment.elements.items[2].value;
                }

                // Parse units - note this is the 5th element (index 4) in SV2
                if (segment.elements.items.len > 4) {
                    service_line.units = segment.elements.items[4].value;
                }

                break; // Only use the first SV2 segment for this service line
            }
        }

        // Find the DTP segment for service dates within this service line's scope
        for (segments) |segment| {
            if (std.mem.eql(u8, segment.id, "DTP") and segment.elements.items.len >= 3) {
                // DTP*472 is service date
                if (std.mem.eql(u8, segment.elements.items[0].value, "472")) {
                    const service_date = segment.elements.items[2].value;
                    if (std.mem.containsAtLeast(u8, service_date, 1, "-")) {
                        var date_iter = std.mem.splitAny(u8, service_date, "-");
                        service_line.service_date = date_iter.first();
                        if (date_iter.next()) |end_date| {
                            service_line.service_date_end = end_date;
                        }
                    } else {
                        service_line.service_date = service_date;
                    }
                    break;
                }
            }
        }

        try claim.service_lines.append(service_line);
    }
};

// Supporting structures

const EntityType = enum {
    unknown,
    person,
    organization,
};

const BillingProvider = struct {
    entity_type: EntityType = .unknown,
    last_name: []const u8 = "",
    first_name: []const u8 = "",
    id_qualifier: []const u8 = "",
    id: []const u8 = "",
    address1: []const u8 = "",
    address2: []const u8 = "",
    city: []const u8 = "",
    state: []const u8 = "",
    zip: []const u8 = "",

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const SubscriberInfo = struct {
    entity_type: EntityType = .unknown,
    last_name: []const u8 = "",
    first_name: []const u8 = "",
    id_qualifier: []const u8 = "",
    id: []const u8 = "",

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const PatientInfo = struct {
    entity_type: EntityType = .unknown,
    last_name: []const u8 = "",
    first_name: []const u8 = "",
    birth_date: []const u8 = "",
    gender: []const u8 = "",

    allocator: Allocator,

    pub fn init(allocator: Allocator) PatientInfo {
        return .{
            .allocator = allocator,
        };
    }
    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const ServiceLine = struct {
    line_number: []const u8 = "",
    revenue_code: ?[]const u8 = null, //Only for Institutional
    procedure_type: []const u8 = "", //HC - HCPCS, HP - HIPPS
    procedure_code: []const u8 = "",
    modifiers: std.ArrayList([]const u8),
    charge_amount: []const u8 = "",
    units: []const u8 = "",
    service_date: []const u8 = "",
    service_date_end: ?[]const u8 = null, //Not always a range

    allocator: Allocator,

    pub fn init(allocator: Allocator) ServiceLine {
        return .{
            .allocator = allocator,
            .modifiers = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ServiceLine) void {
        self.modifiers.deinit();
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const OccurrenceSpanCode = struct {
    code: []const u8 = "",
    qualifier: []const u8 = "",
    from_date: []const u8 = "",
    to_date: []const u8 = "",

    allocator: Allocator,

    pub fn init(allocator: Allocator) OccurrenceSpanCode {
        return .{
            .allocator = allocator,
        };
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const OccurrenceCode = struct {
    code: []const u8 = "",
    date: []const u8 = "",
    qualifier: []const u8 = "",

    allocator: Allocator,

    pub fn init(allocator: Allocator) OccurrenceCode {
        return .{
            .allocator = allocator,
        };
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const ValueCode = struct {
    code: []const u8 = "",
    amount: []const u8 = "",
    qualifier: []const u8 = "",

    allocator: Allocator,

    pub fn init(allocator: Allocator) ValueCode {
        return .{
            .allocator = allocator,
        };
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const Claim = struct {
    claim_id: []const u8 = "",
    total_charges: []const u8 = "",
    place_of_service: []const u8 = "",
    occurrence_span_codes: std.ArrayList(OccurrenceSpanCode),
    occurrence_codes: std.ArrayList(OccurrenceCode),
    value_codes: std.ArrayList(ValueCode),
    condition_codes: std.ArrayList([]const u8),
    diagnosis_codes: std.ArrayList(DiagnosisCode),
    procedure_codes: std.ArrayList(ProcedureCode),
    service_lines: std.ArrayList(ServiceLine),

    allocator: Allocator,

    pub fn init(allocator: Allocator) Claim {
        return .{
            .occurrence_span_codes = std.ArrayList(OccurrenceSpanCode).init(allocator),
            .occurrence_codes = std.ArrayList(OccurrenceCode).init(allocator),
            .value_codes = std.ArrayList(ValueCode).init(allocator),
            .condition_codes = std.ArrayList([]const u8).init(allocator),
            .diagnosis_codes = std.ArrayList(DiagnosisCode).init(allocator),
            .procedure_codes = std.ArrayList(ProcedureCode).init(allocator),
            .service_lines = std.ArrayList(ServiceLine).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Claim) void {
        self.occurrence_span_codes.deinit();
        self.occurrence_codes.deinit();
        self.value_codes.deinit();
        self.condition_codes.deinit();
        self.diagnosis_codes.deinit();
        self.procedure_codes.deinit();

        for (0..self.service_lines.items.len) |line| {
            self.service_lines.items[line].deinit();
        }
        self.service_lines.deinit();
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }

    pub fn processHiType(self: *Claim, element: *const x12.Element, hi_type: HiTypes) !void {
        switch (hi_type) {
            .BI => {
                var occ = OccurrenceSpanCode.init(self.allocator);
                occ.qualifier = element.components.items[0];
                occ.code = element.components.items[1];
                if (element.components.items.len > 3) {
                    const from_date = element.components.items[3];
                    var date_iter = std.mem.splitAny(u8, from_date, "-");
                    occ.from_date = date_iter.first();
                    if (date_iter.next()) |to_date| {
                        occ.to_date = to_date;
                    }
                }
                try self.occurrence_span_codes.append(occ);
            },
            .BH => {
                var occ = OccurrenceCode.init(self.allocator);
                occ.qualifier = element.components.items[0];
                occ.code = element.components.items[1];
                if (element.components.items.len > 3) {
                    occ.date = element.components.items[3];
                }
                try self.occurrence_codes.append(occ);
            },
            .BE => {
                var val = ValueCode.init(self.allocator);
                val.qualifier = element.components.items[0];
                val.code = element.components.items[1];
                // Value amount is typically in position 4
                if (element.components.items.len > 3) {
                    val.amount = element.components.items[4];
                }
                try self.value_codes.append(val);
            },
            .BG => {
                if (element.components.items.len > 1) {
                    try self.condition_codes.append(element.components.items[1]);
                }
            },
        }
    }
};

const SubscriberLoop = struct {
    hl_id: []const u8 = "",
    subscriber: SubscriberInfo = .{},
    sbr_payer_responsibility: []const u8 = "",
    sbr_individual_relationship: []const u8 = "",
    sbr_reference_id: []const u8 = "",
    sbr_claim_filing_code: []const u8 = "",
    patients: std.ArrayList(PatientInfo),
    claims: std.ArrayList(Claim),

    allocator: Allocator,

    pub fn init(allocator: Allocator) SubscriberLoop {
        return .{
            .patients = std.ArrayList(PatientInfo).init(allocator),
            .claims = std.ArrayList(Claim).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubscriberLoop) void {
        self.patients.deinit();
        for (0..self.claims.items.len) |claim| {
            self.claims.items[claim].deinit();
        }
        self.claims.deinit();
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const DiagnosisCode = struct {
    code: []const u8 = "",
    qualifier: []const u8 = "", // BK, BF, etc. - identifies primary vs secondary diagnoses
    poa: []const u8 = "", // Present on Admission indicator (Y, N, U, W, 1)

    pub fn init() DiagnosisCode {
        return .{};
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

const ProcedureCode = struct {
    code: []const u8 = "",
    qualifier: []const u8 = "",

    pub fn init() ProcedureCode {
        return .{};
    }

    pub fn jsonStringify(self: anytype, out: anytype) !void {
        try utils.jsonStringify(self.*, out);
    }
};

test "Parse 837P Professional Claim" {
    // A very minimal 837P example for testing
    const sample_837p =
        \\ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *230101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20230101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*123*20230101*1200*CH~
        \\NM1*41*2*SUBMIT INC*****46*123456789~
        \\PER*IC*CONTACT*TE*5551234~
        \\NM1*40*2*RECEIVER*****46*987654321~
        \\HL*1**20*1~
        \\NM1*85*2*BILLING PROVIDER*****XX*1234567890~
        \\N3*123 MAIN ST~
        \\N4*ANYTOWN*NY*12345~
        \\REF*EI*987654321~
        \\HL*2*1*22*1~
        \\SBR*P*18*******MB~
        \\NM1*IL*1*SMITH*JOHN****MI*123456789A~
        \\N3*456 OAK ST~
        \\N4*ANYTOWN*NY*12345~
        \\DMG*D8*19400101*M~
        \\CLM*123456*150.00***11:B:1*Y*A*Y*Y~
        \\DTP*434*RD8*20220101-20220101~
        \\HI*ABK:R69~
        \\LX*1~
        \\SV1*HC:99213*125.00*UN*1***1~
        \\DTP*472*D8*20220101~
        \\LX*2~
        \\SV1*HC:85025*25.00*UN*1***1~
        \\DTP*472*D8*20220101~
        \\SE*26*0001~
        \\GE*1*1~
        \\IEA*1*000000001~
    ;

    const allocator = std.testing.allocator;

    // Parse the X12 document
    var doc = x12.X12Document.init(allocator);
    defer doc.deinit();
    try doc.parse(sample_837p);

    // Parse as 837 claim
    var claim = Claim837.init(allocator);
    defer claim.deinit();
    try claim.parse(&doc);

    // Verify basic data
    try std.testing.expectEqual(Claim837.TransactionType.professional, claim.transaction_type);
    try std.testing.expectEqualStrings("SENDER", claim.sender_id);
    try std.testing.expectEqualStrings("RECEIVER", claim.receiver_id);

    // Check billing provider
    try std.testing.expectEqualStrings("BILLING PROVIDER", claim.billing_provider.last_name);
    try std.testing.expectEqualStrings("123 MAIN ST", claim.billing_provider.address1);
    try std.testing.expectEqualStrings("NY", claim.billing_provider.state);

    // Check subscriber info
    try std.testing.expect(claim.subscriber_loops.items.len > 0);
}

test "Parse 837P Professional Claim - Comprehensive Test" {
    // A very minimal 837P example for testing
    const sample_837p =
        \\ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *230101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20230101*1200*1*X*005010X222A1~
        \\ST*837*0001*005010X222A1~
        \\BHT*0019*00*123*20230101*1200*CH~
        \\NM1*41*2*SUBMIT INC*****46*123456789~
        \\PER*IC*CONTACT*TE*5551234~
        \\NM1*40*2*RECEIVER*****46*987654321~
        \\HL*1**20*1~
        \\NM1*85*2*BILLING PROVIDER*****XX*1234567890~
        \\N3*123 MAIN ST~
        \\N4*ANYTOWN*NY*12345~
        \\REF*EI*987654321~
        \\HL*2*1*22*1~
        \\SBR*P*18*******MB~
        \\NM1*IL*1*SMITH*JOHN****MI*123456789A~
        \\N3*456 OAK ST~
        \\N4*ANYTOWN*NY*12345~
        \\DMG*D8*19400101*M~
        \\CLM*123456*150.00***11:B:1*Y*A*Y*Y~
        \\DTP*434*RD8*20220101-20220101~
        \\HI*ABK:R69~
        \\LX*1~
        \\SV1*HC:99213*125.00*UN*1***1~
        \\DTP*472*D8*20220101~
        \\LX*2~
        \\SV1*HC:85025*25.00*UN*1***1~
        \\DTP*472*D8*20220101~
        \\SE*26*0001~
        \\GE*1*1~
        \\IEA*1*000000001~
    ;

    const allocator = std.testing.allocator;

    // Parse the X12 document
    var doc = x12.X12Document.init(allocator);
    defer doc.deinit();
    try doc.parse(sample_837p);

    // Parse as 837 claim
    var claim = Claim837.init(allocator);
    defer claim.deinit();
    try claim.parse(&doc);

    // Verify transaction metadata
    try std.testing.expectEqual(Claim837.TransactionType.professional, claim.transaction_type);
    try std.testing.expectEqualStrings("005010X222A1", claim.transaction_control_number);
    try std.testing.expectEqualStrings("SENDER", claim.sender_id);
    try std.testing.expectEqualStrings("RECEIVER", claim.receiver_id);

    // Check billing provider
    try std.testing.expectEqual(EntityType.organization, claim.billing_provider.entity_type);
    try std.testing.expectEqualStrings("BILLING PROVIDER", claim.billing_provider.last_name);
    try std.testing.expectEqualStrings("", claim.billing_provider.first_name);
    try std.testing.expectEqualStrings("XX", claim.billing_provider.id_qualifier);
    try std.testing.expectEqualStrings("1234567890", claim.billing_provider.id);
    try std.testing.expectEqualStrings("123 MAIN ST", claim.billing_provider.address1);
    try std.testing.expectEqualStrings("", claim.billing_provider.address2);
    try std.testing.expectEqualStrings("ANYTOWN", claim.billing_provider.city);
    try std.testing.expectEqualStrings("NY", claim.billing_provider.state);
    try std.testing.expectEqualStrings("12345", claim.billing_provider.zip);

    // Check subscriber loops
    try std.testing.expect(claim.subscriber_loops.items.len > 0);
    const subscriber_loop = claim.subscriber_loops.items[0];
    try std.testing.expectEqualStrings("2", subscriber_loop.hl_id);
    try std.testing.expectEqualStrings("P", subscriber_loop.sbr_payer_responsibility);
    try std.testing.expectEqualStrings("18", subscriber_loop.sbr_individual_relationship);
    try std.testing.expectEqualStrings("", subscriber_loop.sbr_reference_id);
    try std.testing.expectEqualStrings("MB", subscriber_loop.sbr_claim_filing_code);

    // Check subscriber info
    try std.testing.expectEqual(EntityType.person, subscriber_loop.subscriber.entity_type);
    try std.testing.expectEqualStrings("SMITH", subscriber_loop.subscriber.last_name);
    try std.testing.expectEqualStrings("JOHN", subscriber_loop.subscriber.first_name);
    try std.testing.expectEqualStrings("MI", subscriber_loop.subscriber.id_qualifier);
    try std.testing.expectEqualStrings("123456789A", subscriber_loop.subscriber.id);

    // Check patient info (should match subscriber in this case as patient is the subscriber)
    try std.testing.expect(subscriber_loop.patients.items.len > 0);
    const patient = subscriber_loop.patients.items[0];
    try std.testing.expectEqual(EntityType.person, patient.entity_type);
    try std.testing.expectEqualStrings("SMITH", patient.last_name);
    try std.testing.expectEqualStrings("JOHN", patient.first_name);
    try std.testing.expectEqualStrings("19400101", patient.birth_date);
    try std.testing.expectEqualStrings("M", patient.gender);

    // Check claims
    try std.testing.expect(subscriber_loop.claims.items.len > 0);
    const claim_data = subscriber_loop.claims.items[0];
    try std.testing.expectEqualStrings("123456", claim_data.claim_id);
    try std.testing.expectEqualStrings("150.00", claim_data.total_charges);
    try std.testing.expectEqualStrings("11", claim_data.place_of_service);

    // Check diagnosis codes
    try std.testing.expect(claim_data.diagnosis_codes.items.len > 0);
    try std.testing.expectEqualStrings("R69", claim_data.diagnosis_codes.items[0].code);
    try std.testing.expectEqualStrings("ABK", claim_data.diagnosis_codes.items[0].qualifier);

    // Check service lines
    try std.testing.expect(claim_data.service_lines.items.len == 2);

    // First service line
    const line1 = claim_data.service_lines.items[0];
    try std.testing.expectEqualStrings("1", line1.line_number);
    try std.testing.expectEqualStrings("99213", line1.procedure_code);
    try std.testing.expectEqualStrings("125.00", line1.charge_amount);
    try std.testing.expectEqualStrings("1", line1.units);
    try std.testing.expectEqualStrings("20220101", line1.service_date);

    // Second service line
    const line2 = claim_data.service_lines.items[1];
    try std.testing.expectEqualStrings("2", line2.line_number);
    try std.testing.expectEqualStrings("85025", line2.procedure_code);
    try std.testing.expectEqualStrings("25.00", line2.charge_amount);
    try std.testing.expectEqualStrings("1", line2.units);
    try std.testing.expectEqualStrings("20220101", line2.service_date);
}

test "Parse 837I Institutional Claim with Value, Occurrence, and Span Codes" {
    // A more complex 837I example with institutional-specific codes
    const sample_837i =
        \\ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *230101*1200*^*00501*000000001*0*P*:~
        \\GS*HC*SENDER*RECEIVER*20230101*1200*1*X*005010X223A2~
        \\ST*837*0001*005010X223A2~
        \\BHT*0019*00*123*20230101*1200*CH~
        \\NM1*41*2*HOSPITAL INC*****46*123456789~
        \\PER*IC*CONTACT*TE*5551234~
        \\NM1*40*2*INSURANCE CO*****46*987654321~
        \\HL*1**20*1~
        \\NM1*85*2*GENERAL HOSPITAL*****XX*1234567890~
        \\N3*555 HOSPITAL DRIVE~
        \\N4*SOMECITY*CA*90001~
        \\REF*EI*987654321~
        \\HL*2*1*22*1~
        \\SBR*P*18*******MB~
        \\NM1*IL*1*PATIENT*JOHN****MI*123456789A~
        \\N3*123 PATIENT ST~
        \\N4*SOMECITY*CA*90001~
        \\DMG*D8*19500501*M~
        \\CLM*4567832*25000.00***11:B:1*Y*A*Y*Y*A::1*Y*::3~
        \\DTP*434*RD8*20221201-20221210~
        \\HI*ABK:I269*ABF:I4891*ABF:E119*ABF:Z9911~
        \\HI*BE:01:::450.00*BE:02:::600.00*BE:30:::120.00~
        \\HI*BH:A1:D8:20221201*BH:A2:D8:20221130*BH:45:D8:20221201~
        \\HI*BI:70:D8:20221125-20221130*BI:71:D8:20221101-20221110~
        \\LX*1~
        \\SV2*0120*HC:99231*15000.00*UN*10***1~
        \\DTP*472*D8*20221201~
        \\LX*2~
        \\SV2*0270*HC:85025*500.00*UN*5***2~
        \\DTP*472*D8*20221202~
        \\LX*3~
        \\SV2*0450*HC:99291*9500.00*UN*1***3~
        \\DTP*472*D8*20221205~
        \\SE*31*0001~
        \\GE*1*1~
        \\IEA*1*000000001~
    ;
    const allocator = std.testing.allocator;
    // Parse the X12 document
    var doc = x12.X12Document.init(allocator);
    defer doc.deinit();
    try doc.parse(sample_837i);

    // Parse as 837 claim
    var claim = Claim837.init(allocator);
    defer claim.deinit();
    try claim.parse(&doc);

    // Verify transaction metadata
    try std.testing.expectEqual(Claim837.TransactionType.institutional, claim.transaction_type);
    try std.testing.expectEqualStrings("005010X223A2", claim.transaction_control_number);
    try std.testing.expectEqualStrings("SENDER", claim.sender_id);
    try std.testing.expectEqualStrings("RECEIVER", claim.receiver_id);

    // Check billing provider
    try std.testing.expectEqual(EntityType.organization, claim.billing_provider.entity_type);
    try std.testing.expectEqualStrings("GENERAL HOSPITAL", claim.billing_provider.last_name);
    try std.testing.expectEqualStrings("555 HOSPITAL DRIVE", claim.billing_provider.address1);
    try std.testing.expectEqualStrings("CA", claim.billing_provider.state);

    // Check subscriber and patient info
    try std.testing.expect(claim.subscriber_loops.items.len > 0);
    const subscriber_loop = claim.subscriber_loops.items[0];
    try std.testing.expectEqualStrings("PATIENT", subscriber_loop.subscriber.last_name);

    try std.testing.expect(subscriber_loop.patients.items.len > 0);
    const patient = subscriber_loop.patients.items[0];
    try std.testing.expectEqualStrings("19500501", patient.birth_date);
    try std.testing.expectEqualStrings("M", patient.gender);

    // Check claims
    try std.testing.expect(subscriber_loop.claims.items.len > 0);
    const claim_data = subscriber_loop.claims.items[0];
    try std.testing.expectEqualStrings("4567832", claim_data.claim_id);
    try std.testing.expectEqualStrings("25000.00", claim_data.total_charges);

    // Check diagnosis codes - multiple diagnoses
    try std.testing.expectEqual(@as(usize, 4), claim_data.diagnosis_codes.items.len);
    try std.testing.expectEqualStrings("I269", claim_data.diagnosis_codes.items[0].code);
    try std.testing.expectEqualStrings("ABK", claim_data.diagnosis_codes.items[0].qualifier);
    try std.testing.expectEqualStrings("I4891", claim_data.diagnosis_codes.items[1].code);
    try std.testing.expectEqualStrings("ABF", claim_data.diagnosis_codes.items[1].qualifier);

    // Check value codes
    try std.testing.expectEqual(@as(usize, 3), claim_data.value_codes.items.len);
    try std.testing.expectEqualStrings("01", claim_data.value_codes.items[0].code);
    try std.testing.expectEqualStrings("450.00", claim_data.value_codes.items[0].amount);
    try std.testing.expectEqualStrings("02", claim_data.value_codes.items[1].code);
    try std.testing.expectEqualStrings("600.00", claim_data.value_codes.items[1].amount);
    try std.testing.expectEqualStrings("30", claim_data.value_codes.items[2].code);
    try std.testing.expectEqualStrings("120.00", claim_data.value_codes.items[2].amount);

    // Check occurrence codes
    try std.testing.expectEqual(@as(usize, 3), claim_data.occurrence_codes.items.len);
    try std.testing.expectEqualStrings("A1", claim_data.occurrence_codes.items[0].code);
    try std.testing.expectEqualStrings("20221201", claim_data.occurrence_codes.items[0].date);
    try std.testing.expectEqualStrings("A2", claim_data.occurrence_codes.items[1].code);
    try std.testing.expectEqualStrings("20221130", claim_data.occurrence_codes.items[1].date);
    try std.testing.expectEqualStrings("45", claim_data.occurrence_codes.items[2].code);
    try std.testing.expectEqualStrings("20221201", claim_data.occurrence_codes.items[2].date);

    // Check occurrence span codes
    try std.testing.expectEqual(@as(usize, 2), claim_data.occurrence_span_codes.items.len);
    try std.testing.expectEqualStrings("70", claim_data.occurrence_span_codes.items[0].code);
    try std.testing.expectEqualStrings("20221125", claim_data.occurrence_span_codes.items[0].from_date);
    try std.testing.expectEqualStrings("20221130", claim_data.occurrence_span_codes.items[0].to_date);
    try std.testing.expectEqualStrings("71", claim_data.occurrence_span_codes.items[1].code);
    try std.testing.expectEqualStrings("20221101", claim_data.occurrence_span_codes.items[1].from_date);
    try std.testing.expectEqualStrings("20221110", claim_data.occurrence_span_codes.items[1].to_date);

    // Check service lines - ensure we have 3 lines as in the input
    try std.testing.expectEqual(@as(usize, 3), claim_data.service_lines.items.len);

    // First service line
    const line1 = claim_data.service_lines.items[0];
    try std.testing.expectEqualStrings("1", line1.line_number);
    try std.testing.expectEqualStrings("99231", line1.procedure_code);
    try std.testing.expectEqualStrings("15000.00", line1.charge_amount);
    try std.testing.expectEqualStrings("10", line1.units);
    try std.testing.expectEqualStrings("20221201", line1.service_date);

    // Second service line
    const line2 = claim_data.service_lines.items[1];
    try std.testing.expectEqualStrings("2", line2.line_number);
    try std.testing.expectEqualStrings("85025", line2.procedure_code);
    try std.testing.expectEqualStrings("500.00", line2.charge_amount);

    // Third service line
    const line3 = claim_data.service_lines.items[2];
    try std.testing.expectEqualStrings("3", line3.line_number);
    try std.testing.expectEqualStrings("99291", line3.procedure_code);
    try std.testing.expectEqualStrings("9500.00", line3.charge_amount);
    try std.testing.expectEqualStrings("1", line3.units);
}

test "Parse Random sample" {
    // A more complex 837I example with institutional-specific codes
    const sample_837i =
        \\ISA*00*          *00*          *ZZ*000000005D     *ZZ*OO000011111    *180710*2143*^*00501*000001770*1*P*:~
        \\GS*HC*000000005D*OO000011111*20180710*214339*1770*X*005010X222A1~
        \\ST*837*000000001*005010X222A1~
        \\BHT*0019*00*1*20180710*214339*RP~
        \\NM1*41*2*ABCDEF*****46*123456789~
        \\PER*IC*ABCDEF CUSTOMER SOLUTIONS*TE*9999999999~
        \\NM1*40*2*ABCHYI OL POI*****46*YTHF281123456~
        \\HL*1**20*1~
        \\PRV*BI*PXC*1223G0001X~
        \\NM1*85*2*YYYY HEALTHCARE ABC*****XX*1222222220~
        \\N3*123 ADDRESS1~
        \\N4*FAKE CITY*NY*908021112~
        \\REF*EI*123456789~
        \\PER*IC*YYYY HEALTHCARE ABC*TE*1222222221~
        \\NM1*87*2~
        \\N3*123 ADDRESS2~
        \\N4*FAKE CITY*NY*908021112~
        \\HL*2*1*22*0~
        \\SBR*P*18*ABCDE01234******CI~
        \\NM1*IL*1*ABCDEFGH*IJKLMNOP*B***MI*111111100~
        \\N3*123 ADDRESS3~
        \\N4*FAKE CITY*CA*908021112~
        \\DMG*D8*19650101*M~
        \\NM1*PR*2*ABCHYI OL POI*****PI*ABCMMPIO~
        \\CLM*ABC11111*1800***22:B:1*Y*A*Y*Y~
        \\DTP*454*D8*20180123~
        \\DTP*304*D8*20180123~
        \\REF*EA*6123456749~
        \\REF*D9*012345678901234~
        \\NTE*ADD*1513 TO 1641~
        \\HI*ABK:G5621~
        \\NM1*DN*1*ABCD*STUVW****XX*1234567890~
        \\NM1*82*1*TUVWX*MNOPQR****XX*1234567891~
        \\PRV*PE*PXC*367500000X~
        \\NM1*77*2*ABCDEFG HIJKLMN HOSP*****XX*1122334460~
        \\N3*123 ADDRESS4~
        \\N4*FAKE CITY*CA*908021114~
        \\LX*1~
        \\SV1*HC:01710:QZ::::64718*1800*MJ*88***1~
        \\DTP*472*RD8*20180123-20180123~
        \\REF*6R*09876543210~
        \\NTE*ADD*START 1254 STOP 1461~
        \\HL*3**20*1~
        \\PRV*BI*PXC*1223G0001X~
        \\NM1*85*2*ABCDE EFGHIJ GROUP PC*****XX*1222222223~
        \\N3*123 ADDRESS5~
        \\N4*FAKE CITY*CA*908021115~
        \\REF*EI*543211234~
        \\PER*IC*ABCDE EFGHIJ GROUP PC*TE*1222222221~
        \\NM1*87*2~
        \\N3*123 ADDRESS6~
        \\N4*FAKE CITY*CA*908021116~
        \\HL*4*3*22*0~
        \\SBR*P*18*EM00123******MC~
        \\NM1*IL*1*ABCDEFGH*IJKLMNOP*B***MI*11111117~
        \\N3*123 ADDRESS7~
        \\N4*FAKE CITY*CA*908021117~
        \\DMG*D8*19760101*F~
        \\REF*SY*125478963~
        \\NM1*PR*2*ABCHYI OL POI*****PI*ABCMMPIO~
        \\CLM*ABC111112*984***22:B:1*Y*A*Y*Y~
        \\DTP*454*D8*20180713~
        \\DTP*304*D8*20180713~
        \\REF*EA*1254789634~
        \\REF*D9*012345678901231~
        \\HI*ABK:K219~
        \\NM1*DN*1*ABCDEFG*OPQRST*A***XX*1122334460~
        \\NM1*82*1*STUVW*KLMNOP*H***XX*1122334461~
        \\PRV*PE*PXC*207L00000X~
        \\NM1*77*2*ABCDEFG HIJKLMN HOSP*****XX*1122334450~
        \\N3*123 ADDRESS8~
        \\N4*FAKE CITY*CA*908021118~
        \\LX*1~
        \\SV1*HC:00731:AA:P3:::43235*984*MJ*24***1~
        \\DTP*472*RD8*20180713-20180713~
        \\REF*6R*1235478963~
        \\NTE*ADD*START 0822 STOP 0846~
        \\HL*5**20*1~
        \\PRV*BI*PXC*1223G0001X~
        \\NM1*85*2*ABCDE EFGHIJ GROUP PC*****XX*1477527786~
        \\N3*123 ADDRESS9~
        \\N4*FAKE CITY*CA*908021119~
        \\REF*EI*931013923~
        \\PER*IC*ABCDE EFGHIJ GROUP PC*TE*1222222221~
        \\NM1*87*2~
        \\N3*123 ADDRESS10~
        \\N4*FAKE CITY*CA*908021111~
        \\HL*6*5*22*0~
        \\SBR*P*18*EM00003******MC~
        \\NM1*IL*1*ABCDEFGH*IJKLMNOP*B***MI*111111111~
        \\N3*123 ADDRESS11~
        \\N4*FAKE CITY*CA*908021111~
        \\DMG*D8*20180409*M~
        \\NM1*PR*2*ABCHYI OL POI*****PI*YTHF281123456~
        \\CLM*ABC111113*1353***22:B:1*Y*A*Y*Y~
        \\DTP*454*D8*20180713~
        \\DTP*304*D8*20180713~
        \\REF*EA*963852741~
        \\REF*D9*548721986532651~
        \\HI*ABK:K4090~
        \\NM1*DN*1*ABCDEFGH*OPQRSTU*A***XX*1122334456~
        \\NM1*82*1*STUVWX*KLMNOPQ*H***XX*1122334457~
        \\PRV*PE*PXC*207L00000X~
        \\NM1*77*2*ABCDEFG HIJKLMN HOSP*****XX*1122334458~
        \\N3*123 ADDRESS12~
        \\N4*FAKE CITY*CA*908021112~
        \\LX*1~
        \\SV1*HC:00840:AA::::49320*1353*MJ*62***1~
        \\DTP*472*RD8*20180713-20180713~
        \\REF*6R*2154879865~
        \\NTE*ADD*START 0726 STOP 0828~
        \\HL*7*5*22*0~
        \\SBR*P*18*EM00003******MC~
        \\NM1*IL*1*ABCDEFGH*IJKLMNOP*B***MI*111111112~
        \\N3*123 ADDRESS13~
        \\N4*FAKE CITY*CA*908021113~
        \\DMG*D8*20180504*F~
        \\NM1*PR*2*ABCHYI OL POI*****PI*YTHF281123456~
        \\CLM*ABC111114*1968***22:B:1*Y*A*Y*Y~
        \\DTP*454*D8*20180713~
        \\DTP*304*D8*20180713~
        \\REF*EA*123456789~
        \\REF*D9*215487986532544~
        \\HI*ABK:Q423*ABF:G8918~
        \\HI*BG:01*BG:27~
        \\NM1*DN*1*ABCDEFGHI*OPQRSTUV*A***XX*1122334455~
        \\NM1*82*1*STUVWXY*KLMNOPQR*H***XX*1122334456~
        \\PRV*PE*PXC*207L00000X~
        \\NM1*77*2*ABCDEFG HIJKLMN HOSP*****XX*1122334457~
        \\N3*123 ADDRESS15~
        \\N4*FAKE CITY*CA*908021115~
        \\LX*1~
        \\SV1*HC:00902:AA::::46705*1230*MJ*65***1~
        \\DTP*472*RD8*20180713-20180713~
        \\REF*6R*2156325632~
        \\NTE*ADD*START 5248 STOP 1010~
        \\LX*2~
        \\SV1*HC:62322:59*738*UN*1***2~
        \\DTP*472*RD8*20180713-20180713~
        \\REF*6R*2541254125~
        \\SE*138*000000001~
        \\GE*1*1770~
        \\IEA*1*000001770~
    ;
    const allocator = std.testing.allocator;

    // Parse the X12 document
    var doc = x12.X12Document.init(allocator);
    defer doc.deinit();
    try doc.parse(sample_837i);

    // Parse as 837 claim
    var claim = Claim837.init(allocator);
    defer claim.deinit();
    try claim.parse(&doc);
}
