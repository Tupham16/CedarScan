# blender --background --python render.py -- TAG
# Renders raw model.obj vs the rebuilt app preview, app camera (55 deg horizontal FOV, 30 deg elevation,
# centred on the preview bounds), grey clay, back-face culling like MeshPreviewView (.back).
import bpy, sys, math, json, os
import numpy as np
from mathutils import Vector

tag = sys.argv[sys.argv.index("--") + 1]
b = np.load(f"{tag}-bounds.npz")
plo, phi = b["plo"], b["phi"]  # ARKit axes
center_ar = (plo + phi) * 0.5
radius = max(float(np.linalg.norm(phi - plo) * 0.5), 0.5)
center = Vector((center_ar[0], -center_ar[2], center_ar[1]))  # Blender axes

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
sh = scene.display.shading
sh.light = "STUDIO"
sh.color_type = "SINGLE"
sh.single_color = (0.78, 0.78, 0.78)
scene.display.render_aa = "8"
world = bpy.data.worlds.new("w")
world.color = (0.012, 0.012, 0.012)
scene.world = world
scene.render.resolution_x = 1400
scene.render.resolution_y = 1000
scene.render.image_settings.file_format = "PNG"


def load(name):
    bpy.ops.wm.ply_import(filepath=f"{tag}-{name}.ply", forward_axis="Y", up_axis="Z")
    ob = bpy.context.selected_objects[0]
    ob.location = -center
    ob.hide_render = True
    return ob


names = sys.argv[sys.argv.index("--") + 2:] or ["raw", "preview"]
objs = {n: load(n) for n in names}

cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

fov = math.radians(55)
dist = radius / math.tan(fov / 2) * 1.5
elev = math.radians(30)

views = []
for az in (0, 90, 180, 270):
    views.append(("persp", az))
views.append(("top", 0))


def set_view(kind, az):
    a = math.radians(az)
    if kind == "persp":
        cam_data.type = "PERSP"
        cam_data.sensor_fit = "HORIZONTAL"
        cam_data.angle = fov
        cam_data.clip_start = max(0.05, radius * 0.01)
        cam_data.clip_end = dist + radius * 6 + 10
        # app: camera at (0, d sin e, d cos e) in centred ARKit coords -> Blender (0, -d cos e, d sin e)
        p = Vector((0, -dist * math.cos(elev), dist * math.sin(elev)))
        rot = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])
        p = Vector(rot @ np.array(p))
        cam.location = p
        cam.rotation_euler = (math.radians(90) - elev, 0, a)
    else:
        cam_data.type = "ORTHO"
        ext = phi - plo
        cam_data.ortho_scale = float(max(ext[0], ext[2] * 1.4)) * 1.05
        cam_data.clip_start = 0.01
        cam_data.clip_end = 1000
        cam.location = (0, 0, float(ext[1]) + 20)
        cam.rotation_euler = (0, 0, 0)


for kind, az in views:
    set_view(kind, az)
    combos = [(n, True) for n in names] + ([("raw", False)] if "raw" in names else [])
    for name, cull in combos:
        for n, o in objs.items():
            o.hide_render = n != name
        sh.show_backface_culling = cull
        suffix = f"{name}{'-cull' if cull else '-2side'}"
        scene.render.filepath = os.getcwd() + f"/r-{tag}-{kind}{az}-{suffix}.png"
        bpy.ops.render.render(write_still=True)
print("DONE", tag)
