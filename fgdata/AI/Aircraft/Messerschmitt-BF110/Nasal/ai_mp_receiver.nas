###############################################################################
##
##  AI MP Receiver
##  Receives AI model positions and fallback model indices from Office
##  MP broadcaster and updates local proxy AI nodes so bombable and
##  FlightGear can interact with them.
##
##  Listens on Office multiplayer node:
##    string[10] - sync: fallback model indices (27 chars)
##    string[11] - Alpha    string[15] - Echo
##    string[12] - Bravo    string[16] - Foxtrot
##    string[13] - Charlie  string[17] - Golf
##    string[14] - Delta    string[18] - Hotel
##                          string[19] - India
##
##  Position decoding - fixed width 29 chars:
##    chars  0- 8: lat = value / 1000000 - 90
##    chars  9-17: lon = value / 1000000 - 180
##    chars 18-24: alt = value / 10 (feet)
##    chars 25-28: hdg = value / 10 (degrees)
##
##  Sync decoding - 27 chars:
##    9 x 3-digit fallback indices -> sim/model/fallback-model-index
##
##  Copyright (C) 2026 - Aether Project
##
###############################################################################

var AI_MP_Receiver = {};

###############################################################################
# Fixed NATO callsigns - must match broadcaster and scenario XML
AI_MP_Receiver.CALLSIGNS = [
    "Alpha", "Bravo", "Charlie",
    "Delta", "Echo",  "Foxtrot",
    "Golf",  "Hotel", "India"
];

# Constants
AI_MP_Receiver.POS_STRING_FIRST  = 11;
AI_MP_Receiver.SYNC_STRING_IDX   = 10;
AI_MP_Receiver.MODEL_STRIDE      = 29;
AI_MP_Receiver.SERVER_CALLSIGN   = "Office";
AI_MP_Receiver.CHECK_INTERVAL    = 2.0;
AI_MP_Receiver.PROXY_BASE_IDX    = 100;
AI_MP_Receiver.DEFAULT_FALLBACK  = 0;

###############################################################################
# Internal state
AI_MP_Receiver._running       = 0;
AI_MP_Receiver._loopid        = 0;
AI_MP_Receiver._server_node   = nil;
AI_MP_Receiver._proxy_nodes   = {};
AI_MP_Receiver._listeners     = [];
AI_MP_Receiver._sync_listener = nil;

###############################################################################
# Decode one model from 29-char fixed-width string
AI_MP_Receiver._decode_model = func(str) {
    if (str == nil or size(str) < AI_MP_Receiver.MODEL_STRIDE) return nil;
    var ilat = num(substr(str, 0,  9));
    var ilon = num(substr(str, 9,  9));
    var ialt = num(substr(str, 18, 7));
    var ihdg = num(substr(str, 25, 4));
    if (ilat == nil or ilon == nil or ialt == nil or ihdg == nil) return nil;
    if (ilat == 0 and ilon == 0) return nil;
    return {
        lat: ilat / 1000000.0 - 90,
        lon: ilon / 1000000.0 - 180,
        alt: ialt / 10.0,
        hdg: ihdg / 10.0
    };
}

###############################################################################
# Decode sync string - 9 x 3-digit fallback indices
AI_MP_Receiver._decode_sync = func(str) {
    if (str == nil or size(str) < 27) return;
    for (var i = 0; i < size(AI_MP_Receiver.CALLSIGNS); i += 1) {
        var cs  = AI_MP_Receiver.CALLSIGNS[i];
        var idx = num(substr(str, i * 3, 3));
        if (idx == nil) idx = AI_MP_Receiver.DEFAULT_FALLBACK;
        if (!contains(AI_MP_Receiver._proxy_nodes, cs)) continue;
        var proxy = AI_MP_Receiver._proxy_nodes[cs];
        if (proxy == nil) continue;
        proxy.getNode("sim/model/fallback-model-index", 1).setValue(idx);
        print("AI_MP_Receiver: ", cs, " fallback index = ", idx);
    }
}

###############################################################################
# Create proxy AI nodes for all NATO callsigns
AI_MP_Receiver._ensure_proxies = func() {
    for (var i = 0; i < size(AI_MP_Receiver.CALLSIGNS); i += 1) {
        var cs = AI_MP_Receiver.CALLSIGNS[i];
        if (contains(AI_MP_Receiver._proxy_nodes, cs)) continue;
        var proxy_path = "/ai/models/aircraft[" ~
                         (AI_MP_Receiver.PROXY_BASE_IDX + i) ~ "]";
        var proxy = props.globals.getNode(proxy_path, 1);
        proxy.getNode("valid",    1).setValue(1);
        proxy.getNode("callsign", 1).setValue(cs);
        proxy.getNode("type",     1).setValue("AI");
        proxy.getNode("sim/model/fallback-model-index", 1).setValue(
            AI_MP_Receiver.DEFAULT_FALLBACK);
        proxy.getNode("position/latitude-deg",        1).setValue(0);
        proxy.getNode("position/longitude-deg",       1).setValue(0);
        proxy.getNode("position/altitude-ft",         1).setValue(0);
        proxy.getNode("orientation/true-heading-deg", 1).setValue(0);
        AI_MP_Receiver._proxy_nodes[cs] = proxy;
        print("AI_MP_Receiver: proxy created for ", cs);
    }
}

###############################################################################
# Update proxy position
AI_MP_Receiver._update_proxy = func(callsign, pos) {
    if (!contains(AI_MP_Receiver._proxy_nodes, callsign)) return;
    var proxy = AI_MP_Receiver._proxy_nodes[callsign];
    if (proxy == nil) return;
    proxy.getNode("position/latitude-deg",        1).setValue(pos.lat);
    proxy.getNode("position/longitude-deg",       1).setValue(pos.lon);
    proxy.getNode("position/altitude-ft",         1).setValue(pos.alt);
    proxy.getNode("orientation/true-heading-deg", 1).setValue(pos.hdg);
}

###############################################################################
# Called when position string changes - one string per model
AI_MP_Receiver._on_position_string = func(str_node, model_idx) {
    var str = str_node.getValue();
    if (str == nil or str == "") return;
    var cs  = AI_MP_Receiver.CALLSIGNS[model_idx];
    var pos = AI_MP_Receiver._decode_model(str);
    if (pos != nil) AI_MP_Receiver._update_proxy(cs, pos);
}

###############################################################################
# Find Office in MP list
AI_MP_Receiver._find_server = func() {
    var mp_list = props.globals.getNode("/ai/models").getChildren("multiplayer");
    foreach (var p; mp_list) {
        var cs = p.getNode("callsign");
        if (cs != nil and cs.getValue() == AI_MP_Receiver.SERVER_CALLSIGN) {
            return p;
        }
    }
    return nil;
}

###############################################################################
# Set up listeners - one per model + sync
AI_MP_Receiver._setup_listeners = func(server_node) {
    AI_MP_Receiver._clear_listeners();
    var base = server_node.getPath();

    # Position listeners - one per model
    for (var i = 0; i < size(AI_MP_Receiver.CALLSIGNS); i += 1) {
        var idx = AI_MP_Receiver.POS_STRING_FIRST + i;
        var str_path = base ~ "/sim/multiplay/generic/string[" ~ idx ~ "]";
        props.globals.getNode(str_path, 1);
        var lid = setlistener(str_path,
            (func(midx) { return func(n) {
                AI_MP_Receiver._on_position_string(n, midx);
            };})(i),
        0, 0);
        append(AI_MP_Receiver._listeners, lid);
    }

    # Sync listener - fallback model indices
    var sync_path = base ~ "/sim/multiplay/generic/string[" ~
                    AI_MP_Receiver.SYNC_STRING_IDX ~ "]";
    props.globals.getNode(sync_path, 1);
    AI_MP_Receiver._sync_listener = setlistener(sync_path, func(n) {
        AI_MP_Receiver._decode_sync(n.getValue());
    }, 1, 0);

    print("AI_MP_Receiver: listeners set up on ", base);
}

###############################################################################
# Clear listeners
AI_MP_Receiver._clear_listeners = func() {
    foreach (var lid; AI_MP_Receiver._listeners) {
        removelistener(lid);
    }
    AI_MP_Receiver._listeners = [];
    if (AI_MP_Receiver._sync_listener != nil) {
        removelistener(AI_MP_Receiver._sync_listener);
        AI_MP_Receiver._sync_listener = nil;
    }
}

###############################################################################
# Watch loop - looks for Office in MP list
AI_MP_Receiver._watch_loop = func(id) {
    if (!AI_MP_Receiver._running) return;
    if (id != AI_MP_Receiver._loopid) return;
    var server = AI_MP_Receiver._find_server();
    if (server != nil and AI_MP_Receiver._server_node == nil) {
        print("AI_MP_Receiver: Office found! Setting up...");
        AI_MP_Receiver._server_node = server;
        AI_MP_Receiver._ensure_proxies();
        AI_MP_Receiver._setup_listeners(server);
    } elsif (server == nil and AI_MP_Receiver._server_node != nil) {
        print("AI_MP_Receiver: Office disconnected.");
        AI_MP_Receiver._server_node = nil;
        AI_MP_Receiver._clear_listeners();
    }
    settimer(func { AI_MP_Receiver._watch_loop(id); },
             AI_MP_Receiver.CHECK_INTERVAL);
}

###############################################################################
# Start
AI_MP_Receiver.start = func() {
    if (AI_MP_Receiver._running) {
        print("AI_MP_Receiver: already running."); return;
    }
    AI_MP_Receiver._running = 1;
    AI_MP_Receiver._loopid += 1;
    settimer(func { AI_MP_Receiver._watch_loop(AI_MP_Receiver._loopid); },
             AI_MP_Receiver.CHECK_INTERVAL);
    print("AI_MP_Receiver: started. Watching for Office...");
}

###############################################################################
# Stop
AI_MP_Receiver.stop = func() {
    AI_MP_Receiver._running = 0;
    AI_MP_Receiver._loopid += 1;
    AI_MP_Receiver._clear_listeners();
    AI_MP_Receiver._server_node = nil;
    print("AI_MP_Receiver: stopped.");
}

###############################################################################
# Auto-start
AI_MP_Receiver.start();
