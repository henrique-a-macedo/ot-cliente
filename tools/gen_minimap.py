#!/usr/bin/env python3
"""Builds a fully explored minimap (.otmm) from a server map, so players start with the whole minimap.

Usage:
    python3 tools/gen_minimap.py <appearances.dat> <server items.otb> <map.otbm> <out .otmm>
    e.g. python3 tools/gen_minimap.py data/things/1310/appearances-<hash>.dat \
             ../forgottenserver/data/items/items.otb ../forgottenserver/data/world/map.otbm data/minimap.otmm

The client builds the same data while walking (src/client/minimap.cpp, Minimap::updateTile): per tile a color
(Tile::getMinimapColorByte: the first automap color among top, bottom, border and ground items, from the top), the
flags "seen", "not walkable" (no ground or an unpass item) and "not pathable" (an avoid item), and the ground speed.
The file format is Minimap::saveOtmm: header, then 64x64 blocks of 3-byte tiles, each block zlib-compressed.
Only the standard library is used; the map is streamed.
"""
import struct
import sys
import zlib

# ---------- appearances.dat (src/protobuf/appearances.proto): only what the minimap needs

def varint(data, i):
    shift = result = 0
    while True:
        b = data[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def fields(data):
    """yields (field number, wire type, value) of a protobuf message; length-delimited values are memoryviews"""
    i, end = 0, len(data)
    while i < end:
        key, i = varint(data, i)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, i = varint(data, i)
        elif wire == 2:
            size, i = varint(data, i)
            value, i = data[i:i + size], i + size
        elif wire == 5:
            value, i = struct.unpack_from("<I", data, i)[0], i + 4
        elif wire == 1:
            value, i = struct.unpack_from("<Q", data, i)[0], i + 8
        else:
            raise ValueError(f"unsupported wire type {wire}")
        yield number, wire, value


GROUND, BORDER, BOTTOM, TOP = 0, 1, 2, 3  # client stack order (Tile::addThing); anything else is "common"


class Look:
    __slots__ = ("color", "layer", "unpass", "avoid", "speed")

    def __init__(self):
        self.color, self.layer, self.unpass, self.avoid, self.speed = 0, None, False, False, 0


def read_appearances(path):
    """{client id: Look} for the objects (items) of appearances.dat"""
    data = memoryview(open(path, "rb").read())
    looks = {}
    for number, _, appearance in fields(data):
        if number != 1:  # Appearances.object
            continue
        look, client_id = Look(), None
        for a_number, _, a_value in fields(appearance):
            if a_number == 1:
                client_id = a_value
            elif a_number == 3:  # flags
                for f_number, _, f_value in fields(a_value):
                    if f_number == 1:  # bank
                        look.layer = GROUND
                        for b_number, _, b_value in fields(f_value):
                            if b_number == 1:
                                look.speed = b_value
                    elif f_number == 2 and f_value and look.layer is None:
                        look.layer = BORDER
                    elif f_number == 3 and f_value and look.layer is None:
                        look.layer = BOTTOM
                    elif f_number == 4 and f_value and look.layer is None:
                        look.layer = TOP
                    elif f_number == 13:
                        look.unpass = bool(f_value)
                    elif f_number == 16:
                        look.avoid = bool(f_value)
                    elif f_number == 30:  # automap
                        for c_number, _, c_value in fields(f_value):
                            if c_number == 1:
                                look.color = c_value
        if client_id is not None:
            looks[client_id] = look
    return looks


# ---------- items.otb and map.otbm (the format the server reads: src/iomap.h)

NODE_ESC, NODE_START, NODE_END = 0xFD, 0xFE, 0xFF
OTBM_TILE_AREA, OTBM_TILE, OTBM_ITEM, OTBM_HOUSETILE = 4, 5, 6, 14
OTBM_ATTR_TILE_FLAGS = 3
TOP_ITEM_DEPTH = 4  # root > map data > tile area > tile > item


def read_client_ids(path):
    """{server id: client id} from items.otb"""
    data = open(path, "rb").read()
    out, i, depth, props = {}, 4, 0, bytearray()
    while i < len(data):
        c = data[i]
        if c == NODE_START:
            depth, props, i = depth + 1, bytearray(), i + 2
            continue
        if c == NODE_END:
            if depth == 2:
                attrs, j = {}, 4
                while j < len(props):
                    size = struct.unpack_from("<H", props, j + 1)[0]
                    attrs[props[j]] = bytes(props[j + 3:j + 3 + size])
                    j += 3 + size
                if 0x10 in attrs and 0x11 in attrs:
                    out[struct.unpack("<H", attrs[0x10])[0]] = struct.unpack("<H", attrs[0x11])[0]
            depth, i = depth - 1, i + 1
            continue
        if c == NODE_ESC:
            i += 1
            c = data[i]
        props.append(c)
        i += 1
    return out


def iter_tiles(data):
    """yields ((x, y, z), [server item ids]): the inline ground and the top-level items, in map order"""
    stack, i = [], 4
    base, tile, items = (0, 0, 0), None, None

    def node(node_type, props, depth):
        nonlocal base, tile, items
        if node_type == OTBM_TILE_AREA:
            base = struct.unpack_from("<HHB", props, 0)
        elif node_type in (OTBM_TILE, OTBM_HOUSETILE):
            result = (tile, items) if tile else None
            tile, items = (base[0] + props[0], base[1] + props[1], base[2]), []
            j = 2 if node_type == OTBM_TILE else 6
            while j < len(props):
                if props[j] == OTBM_ATTR_TILE_FLAGS:
                    j += 5
                else:
                    items.append(struct.unpack_from("<H", props, j + 1)[0])
                    j += 3
            return result
        elif node_type == OTBM_ITEM and depth == TOP_ITEM_DEPTH and tile:
            items.append(struct.unpack_from("<H", props, 0)[0])
        return None

    while i < len(data):
        c = data[i]
        if c == NODE_START:
            if stack and stack[-1][2]:
                done = node(stack[-1][0], bytes(stack[-1][1]), len(stack) - 1)
                stack[-1][2] = False
                if done:
                    yield done
            stack.append([data[i + 1], bytearray(), True])
            i += 2
        elif c == NODE_END:
            node_type, props, pending = stack.pop()
            if pending:
                done = node(node_type, bytes(props), len(stack))
                if done:
                    yield done
            i += 1
            if not stack:
                break
        else:
            if c == NODE_ESC:
                i += 1
                c = data[i]
            stack[-1][1].append(c)
            i += 1
    if tile:
        yield tile, items


# ---------- minimap

MMBLOCK_SIZE = 64
OTMM_SIGNATURE, OTMM_VERSION = 0x4D4D544F, 1
SEEN, NOT_PATHABLE, NOT_WALKABLE = 1, 2, 4
EMPTY_TILE = bytes([0, 255, 10])  # MinimapTile defaults (flags, color, speed)


def minimap_tile(looks, client_ids, items):
    """3 bytes (flags, color, speed) as Minimap::updateTile writes them"""
    things = [looks.get(client_ids.get(i)) for i in items]
    things = [t for t in things if t is not None]
    ground = next((t for t in things if t.layer == GROUND), None)
    color = 255
    for layer in (TOP, BOTTOM, BORDER, GROUND):
        for thing in reversed(things):
            if thing.layer == layer and thing.color:
                color = thing.color
                break
        else:
            continue
        break
    flags = SEEN
    if not ground or any(t.unpass for t in things):
        flags |= NOT_WALKABLE
    if any(t.avoid for t in things):
        flags |= NOT_PATHABLE
    speed = min(-(-(ground.speed if ground and ground.speed else 100) // 10), 255)
    return bytes([flags, color, speed])


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    appearances, items_otb, map_path, out_path = sys.argv[1:5]
    looks = read_appearances(appearances)
    client_ids = read_client_ids(items_otb)
    blocks = {}  # (bx, by, z) -> bytearray(64*64*3)
    tiles = 0
    with open(map_path, "rb") as f:
        data = f.read()
    for (x, y, z), items in iter_tiles(data):
        key = (x - x % MMBLOCK_SIZE, y - y % MMBLOCK_SIZE, z)
        block = blocks.get(key)
        if block is None:
            block = blocks[key] = bytearray(EMPTY_TILE * (MMBLOCK_SIZE * MMBLOCK_SIZE))
        offset = ((y % MMBLOCK_SIZE) * MMBLOCK_SIZE + (x % MMBLOCK_SIZE)) * 3
        block[offset:offset + 3] = minimap_tile(looks, client_ids, items)
        tiles += 1

    with open(out_path, "wb") as out:
        description = b"OTMM 1.0"
        header = struct.pack("<IHHI", OTMM_SIGNATURE, 0, OTMM_VERSION, 0) + struct.pack("<H", len(description)) + description
        out.write(struct.pack("<IHHI", OTMM_SIGNATURE, len(header), OTMM_VERSION, 0))
        out.write(struct.pack("<H", len(description)) + description)
        for (bx, by, z) in sorted(blocks, key=lambda k: (k[2], k[1], k[0])):
            packed = zlib.compress(bytes(blocks[(bx, by, z)]), 3)
            out.write(struct.pack("<HHBH", bx, by, z, len(packed)) + packed)
        out.write(struct.pack("<HHB", 0xFFFF, 0xFFFF, 0xFF))
    print(f"{tiles} tiles, {len(blocks)} blocks of {MMBLOCK_SIZE}x{MMBLOCK_SIZE}, {len(looks)} appearances -> {out_path}")


if __name__ == "__main__":
    main()
