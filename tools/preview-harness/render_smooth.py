# blender --background --python render_smooth.py -- TAG PX PY AZ DIST NAME...
# Like render_zoom.py, but SMOOTH shading the way the app draws it: per-vertex normals from
# TAG-NAME-normals.npy (ARKit axes, = PreviewSimplifier.finish) when present, else Blender's own smooth normals.
import bpy, sys, math, os
import numpy as np
from mathutils import Vector
args = sys.argv[sys.argv.index("--") + 1:]
tag, px, py, az, dd = args[0], float(args[1]), float(args[2]), float(args[3]), float(args[4])
names = args[5:]
b = np.load(f"{tag}-bounds.npz"); plo, phi = b["plo"], b["phi"]
c = (plo + phi) * 0.5; center = Vector((c[0], -c[2], c[1]))
ext = phi - plo
ortho = float(max(ext[0], ext[2] * 1.4)) * 1.05
tx = (px - 700) / 1400 * ortho; ty = (500 - py) / 1400 * ortho
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene; sc.render.engine = "BLENDER_WORKBENCH"
sh = sc.display.shading; sh.light = "STUDIO"; sh.color_type = "SINGLE"; sh.single_color = (0.78, 0.78, 0.78)
sc.display.render_aa = "8"; w = bpy.data.worlds.new("w"); w.color = (0.012, 0.012, 0.012); sc.world = w
sc.render.resolution_x = 1000; sc.render.resolution_y = 750
objs = {}
for n in names:
    bpy.ops.wm.ply_import(filepath=os.getcwd() + f"/{tag}-{n}.ply", forward_axis="Y", up_axis="Z")
    o = bpy.context.selected_objects[0]; o.location = -center; o.hide_render = True; objs[n] = o
    me = o.data
    me.shade_smooth()
    nf = f"{tag}-{n}-normals.npy"
    if os.path.exists(nf):
        N = np.load(nf).astype(np.float64)
        Nb = np.stack([N[:, 0], -N[:, 2], N[:, 1]], 1)  # ARKit -> Blender axes, same as write_ply
        assert len(Nb) == len(me.vertices), (len(Nb), len(me.vertices))
        me.normals_split_custom_set_from_vertices([tuple(v) for v in Nb])
cd = bpy.data.cameras.new("c"); cam = bpy.data.objects.new("c", cd); sc.collection.objects.link(cam); sc.camera = cam
cd.sensor_fit = "HORIZONTAL"; cd.angle = math.radians(55); cd.clip_start = 0.05; cd.clip_end = 500
e = math.radians(float(os.environ.get("ELEV", "40"))); a = math.radians(az)
off = Vector((math.sin(a) * dd * math.cos(e), -math.cos(a) * dd * math.cos(e), dd * math.sin(e)))
target = Vector((tx, ty, -ext[1] * 0.25))
cam.location = target + off
cam.rotation_euler = (math.radians(90) - e, 0, a)
sh.show_backface_culling = True
for n in names:
    for k, o in objs.items(): o.hide_render = k != n
    sc.render.filepath = os.getcwd() + f"/s-{tag}-{int(px)}-{int(py)}-{int(az)}-{n}.png"
    bpy.ops.render.render(write_still=True)
print("DONE")
