#!/usr/bin/env python3
"""Generate the game's aircraft meshes as glTF 2.0 binaries.

The shipped widebody came from an external tool and only covers one class, so
Regional and Narrowbody were being drawn as the same silhouette at a smaller
scale. This emits one parametric airliner per class instead.

Deliberately matched to the existing art direction, which the renderer depends
on:

  * Flat material colours, no textures and no UVs. `Render3D` uses
    StandardMaterial3D albedo throughout and never samples a texture.
  * A material literally named "livery". `Render3D._tint_livery()` finds
    surfaces whose material `resource_name` is "livery" and overrides their
    albedo per airline, so that name is load-bearing — renaming it silently
    turns every aircraft white.
  * Nose down -Z. That is Godot's forward convention and what
    `Render3D.yaw_for_heading()` already assumes.
  * Lowest point at y = 0, so an aircraft sits on the pavement with no offset.

Run:  python3 scripts/generate_aircraft.py
Out:  assets/models/{regional,narrowbody,widebody}.glb
"""

import json
import math
import os
import struct

MATERIALS = [
    ("shell", (0.815, 0.799, 0.753)),
    ("livery", (0.012, 0.047, 0.125)),
    ("glass", (0.007, 0.009, 0.013)),
    ("engine", (0.680, 0.665, 0.624)),
    ("dark", (0.016, 0.018, 0.023)),
    ("belly", (0.485, 0.503, 0.527)),
]
MAT_INDEX = {name: i for i, (name, _) in enumerate(MATERIALS)}


class Mesh:
    """Positions/normals accumulated per material, emitted as one primitive each."""

    def __init__(self):
        self.groups = {name: {"v": [], "n": [], "i": []} for name, _ in MATERIALS}

    def tri(self, mat, a, b, c):
        g = self.groups[mat]
        u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
        v = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
        n = (u[1] * v[2] - u[2] * v[1],
             u[2] * v[0] - u[0] * v[2],
             u[0] * v[1] - u[1] * v[0])
        ln = math.sqrt(sum(x * x for x in n)) or 1.0
        n = (n[0] / ln, n[1] / ln, n[2] / ln)
        base = len(g["v"])
        for p in (a, b, c):
            g["v"].append(p)
            g["n"].append(n)
        g["i"] += [base, base + 1, base + 2]

    def quad(self, mat, a, b, c, d):
        self.tri(mat, a, b, c)
        self.tri(mat, a, c, d)

    def box(self, mat, centre, size, yaw=0.0):
        cx, cy, cz = centre
        sx, sy, sz = (s * 0.5 for s in size)
        pts = []
        for dx, dy, dz in [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                           (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]:
            x, z = dx * sx, dz * sz
            if yaw:
                x, z = x * math.cos(yaw) - z * math.sin(yaw), x * math.sin(yaw) + z * math.cos(yaw)
            pts.append((cx + x, cy + dy * sy, cz + z))
        for f in [(0, 1, 2, 3), (5, 4, 7, 6), (4, 0, 3, 7),
                  (1, 5, 6, 2), (4, 5, 1, 0), (3, 2, 6, 7)]:
            self.quad(mat, *[pts[i] for i in f])

    def tube(self, mat, sections, segments=12, cx=0.0):
        """sections: [(z, centre_y, radius)] lofted nose-to-tail, centred on cx."""
        rings = []
        for z, cy, r in sections:
            ring = []
            for s in range(segments):
                a = math.tau * s / segments
                ring.append((cx + math.sin(a) * r, cy + math.cos(a) * r, z))
            rings.append(ring)
        for i in range(len(rings) - 1):
            for s in range(segments):
                t = (s + 1) % segments
                self.quad(mat, rings[i][s], rings[i][t], rings[i + 1][t], rings[i + 1][s])
        # Cap the tail so the fuselage is not open.
        last = rings[-1]
        cz = sections[-1][0]
        centre = (cx, sections[-1][1], cz)
        for s in range(segments):
            self.tri(mat, last[(s + 1) % segments], last[s], centre)


def wing(mesh, mat, root_z, span, root_chord, tip_chord, sweep, y, thick, dihedral=0.6):
    """One swept, tapered wing plus its mirror."""
    for side in (1, -1):
        tip_x = side * span
        tip_y = y + dihedral
        root_f, root_b = root_z - root_chord * 0.5, root_z + root_chord * 0.5
        tip_f, tip_b = root_f + sweep, root_f + sweep + tip_chord
        top = [(0, y + thick, root_f), (tip_x, tip_y + thick * 0.4, tip_f),
               (tip_x, tip_y + thick * 0.4, tip_b), (0, y + thick, root_b)]
        bot = [(0, y, root_f), (tip_x, tip_y, tip_f),
               (tip_x, tip_y, tip_b), (0, y, root_b)]
        if side < 0:
            top = top[::-1]
            bot = bot[::-1]
        mesh.quad(mat, *top)
        mesh.quad(mat, *bot[::-1])
        for i in range(4):
            j = (i + 1) % 4
            mesh.quad(mat, bot[i], bot[j], top[j], top[i])


def build(kind):
    """Real-world proportions per class; the renderer normalises to screen size."""
    spec = {
        "regional":   dict(length=30.0, radius=1.45, span=13.0, engines=2, tail_h=6.4),
        "narrowbody": dict(length=40.0, radius=1.90, span=17.5, engines=2, tail_h=8.4),
        "widebody":   dict(length=66.0, radius=3.10, span=31.0, engines=4, tail_h=13.0),
    }[kind]

    L, R = spec["length"], spec["radius"]
    m = Mesh()
    # Belly clearance so the gear has somewhere to go and y=0 is the ground.
    cy = R + R * 0.55

    nose, tail = -L * 0.5, L * 0.5
    sections = []
    for i in range(15):
        t = i / 14.0
        z = nose + L * t
        if t < 0.12:                      # nose cone
            r = R * math.sin(t / 0.12 * math.pi * 0.5) ** 0.7
            y = cy - R * 0.10 * (1 - t / 0.12)
        elif t > 0.78:                    # tail cone, sweeping up
            u = (t - 0.78) / 0.22
            r = R * max(0.06, 1.0 - u ** 1.6)
            y = cy + R * 0.55 * u ** 1.7
        else:
            r, y = R, cy
        sections.append((z, y, r))
    m.tube("shell", sections)

    # Cheatline down the flank, and the fin — both livery, so an airline reads
    # from its colours at a glance.
    for side in (1, -1):
        m.box("livery", (side * R * 0.94, cy - R * 0.02, 0.0),
              (R * 0.10, R * 0.14, L * 0.60))

    wing(m, "shell", root_z=L * 0.04, span=spec["span"], root_chord=L * 0.20,
         tip_chord=L * 0.07, sweep=L * 0.10, y=cy - R * 0.62, thick=R * 0.16)
    wing(m, "shell", root_z=tail - L * 0.06, span=spec["span"] * 0.34,
         root_chord=L * 0.09, tip_chord=L * 0.035, sweep=L * 0.045,
         y=cy + R * 0.42, thick=R * 0.09, dihedral=0.2)

    # Vertical fin.
    fz, fh = tail - L * 0.09, spec["tail_h"]
    # One tapered solid. Stacking slabs to fake the taper produced a visible
    # staircase along the leading edge.
    ry, ty = cy + R * 0.42, cy + R * 0.42 + fh
    rf, rb = fz - L * 0.10, fz + L * 0.055
    tf, tb = fz + L * 0.020, fz + L * 0.065
    hw = R * 0.075
    for side in (1, -1):
        root = [(side * hw, ry, rf), (side * hw, ry, rb)]
        tip = [(side * hw, ty, tf), (side * hw, ty, tb)]
        if side > 0:
            m.quad("livery", root[0], root[1], tip[1], tip[0])
        else:
            m.quad("livery", tip[0], tip[1], root[1], root[0])
    m.quad("livery", (-hw, ry, rf), (hw, ry, rf), (hw, ty, tf), (-hw, ty, tf))   # leading
    m.quad("livery", (hw, ry, rb), (-hw, ry, rb), (-hw, ty, tb), (hw, ty, tb))   # trailing
    m.quad("livery", (-hw, ty, tf), (hw, ty, tf), (hw, ty, tb), (-hw, ty, tb))   # cap

    # Engines: two per wing on the widebody, one otherwise.
    er, el = R * 0.52, L * 0.14
    mounts = [0.42, 0.72] if spec["engines"] == 4 else [0.46]
    for side in (1, -1):
        for f in mounts:
            ex = side * spec["span"] * f
            ez = L * 0.04 - L * 0.10 - abs(ex) * 0.16
            ey = cy - R * 0.62 - er * 0.55
            m.tube("engine", [(ez - el, ey, er * 0.72), (ez - el * 0.5, ey, er),
                              (ez + el * 0.6, ey, er * 0.92)], segments=10, cx=ex)
            m.tube("dark", [(ez - el * 1.04, ey, er * 0.58),
                            (ez - el * 0.96, ey, er * 0.58)], segments=10, cx=ex)
            # Pylon up to the wing, or the nacelle floats.
            m.box("dark", (ex, ey + er * 0.8, ez), (er * 0.16, er * 1.1, el * 0.7))

    # Flight-deck glazing and a window band.
    m.box("glass", (0.0, cy + R * 0.46, nose + L * 0.085), (R * 0.72, R * 0.20, L * 0.030))
    for side in (1, -1):
        m.box("glass", (side * R * 0.95, cy + R * 0.30, L * 0.02),
              (R * 0.05, R * 0.10, L * 0.54))

    # Gear: struts down to y=0 so the aircraft rests on the pavement.
    m.box("dark", (0.0, (cy - R) * 0.5, nose + L * 0.10), (R * 0.16, cy - R, R * 0.3))
    for side in (1, -1):
        m.box("dark", (side * R * 0.55, (cy - R) * 0.5, L * 0.08),
              (R * 0.20, cy - R, R * 0.36))
    return m


def to_glb(mesh):
    blob = bytearray()
    accessors, views, prims = [], [], []

    def add_view(data, target):
        while len(blob) % 4:
            blob.append(0)
        off = len(blob)
        blob.extend(data)
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        return len(views) - 1

    for name, _ in MATERIALS:
        g = mesh.groups[name]
        if not g["i"]:
            continue
        vb = b"".join(struct.pack("<3f", *p) for p in g["v"])
        nb = b"".join(struct.pack("<3f", *p) for p in g["n"])
        ib = b"".join(struct.pack("<I", i) for i in g["i"])
        vi, ni, ii = add_view(vb, 34962), add_view(nb, 34962), add_view(ib, 34963)
        mn = [min(p[k] for p in g["v"]) for k in range(3)]
        mx = [max(p[k] for p in g["v"]) for k in range(3)]
        accessors.append({"bufferView": vi, "componentType": 5126,
                          "count": len(g["v"]), "type": "VEC3", "min": mn, "max": mx})
        accessors.append({"bufferView": ni, "componentType": 5126,
                          "count": len(g["n"]), "type": "VEC3"})
        accessors.append({"bufferView": ii, "componentType": 5125,
                          "count": len(g["i"]), "type": "SCALAR"})
        prims.append({"attributes": {"POSITION": len(accessors) - 3,
                                     "NORMAL": len(accessors) - 2},
                      "indices": len(accessors) - 1,
                      "material": MAT_INDEX[name]})

    gltf = {
        "asset": {"version": "2.0", "generator": "airport/scripts/generate_aircraft.py"},
        "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0}],
        "meshes": [{"primitives": prims}],
        "materials": [
            {"name": n,
             "pbrMetallicRoughness": {"baseColorFactor": list(c) + [1.0],
                                      "metallicFactor": 0.0, "roughnessFactor": 0.75}}
            for n, c in MATERIALS],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views, "accessors": accessors,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    while len(blob) % 4:
        blob.append(0)
    return (b"glTF" + struct.pack("<II", 2, 12 + 8 + len(js) + 8 + len(blob))
            + struct.pack("<II", len(js), 0x4E4F534A) + js
            + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


def main():
    out = os.path.join(os.path.dirname(__file__), "..", "assets", "models")
    os.makedirs(out, exist_ok=True)
    for kind in ("regional", "narrowbody", "widebody"):
        m = build(kind)
        data = to_glb(m)
        path = os.path.join(out, "%s.glb" % kind)
        with open(path, "wb") as f:
            f.write(data)
        verts = sum(len(g["v"]) for g in m.groups.values())
        tris = sum(len(g["i"]) for g in m.groups.values()) // 3
        ys = [p[1] for g in m.groups.values() for p in g["v"]]
        zs = [p[2] for g in m.groups.values() for p in g["v"]]
        print("%-11s %6d B  %5d tris  len=%.1f  ground=%.3f"
              % (kind, len(data), tris, max(zs) - min(zs), min(ys)))


if __name__ == "__main__":
    main()
