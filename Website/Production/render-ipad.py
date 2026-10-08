"""Render the supplied official device geometry with an unchanged app capture."""
from pathlib import Path
import bpy
from mathutils import Vector

root = Path(__file__).resolve().parents[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=str(root / 'Production/ipad-pro-space-black.usdz'))
screen = bpy.data.objects['lsDiIbtoSGSmWWZ']
material = bpy.data.materials.new('MirrorMirror actual app capture')
material.use_nodes = True
nodes = material.node_tree.nodes
nodes.clear()
output = nodes.new('ShaderNodeOutputMaterial')
shader = nodes.new('ShaderNodeEmission')
shader.inputs['Strength'].default_value = 1
texture = nodes.new('ShaderNodeTexImage')
texture.image = bpy.data.images.load(str(root / 'assets/captures/ipad-home.png'))
texture.extension = 'CLIP'
uv = nodes.new('ShaderNodeTexCoord')
separate = nodes.new('ShaderNodeSeparateXYZ')
subtract = nodes.new('ShaderNodeMath'); subtract.operation = 'SUBTRACT'; subtract.inputs[0].default_value = 1
combine = nodes.new('ShaderNodeCombineXYZ')
links = material.node_tree.links
links.new(uv.outputs['UV'], separate.inputs[0])
links.new(separate.outputs['Y'], subtract.inputs[1])
links.new(subtract.outputs[0], combine.inputs['X'])
fit = nodes.new('ShaderNodeMath'); fit.operation = 'MULTIPLY_ADD'
fit.inputs[1].default_value = (1194 / 834) / (4 / 3)
fit.inputs[2].default_value = (1 - fit.inputs[1].default_value) / 2
links.new(separate.outputs['X'], fit.inputs[0])
links.new(fit.outputs[0], combine.inputs['Y'])
links.new(combine.outputs[0], texture.inputs['Vector'])
links.new(texture.outputs['Color'], shader.inputs['Color'])
links.new(shader.outputs[0], output.inputs['Surface'])
screen.data.materials.clear(); screen.data.materials.append(material)
center = sum((screen.matrix_world @ Vector(corner) for corner in screen.bound_box), Vector()) / 8
normal = (screen.matrix_world.to_3x3() @ screen.data.polygons[0].normal).normalized()
right = Vector((1, 0, 0))
up = normal.cross(right).normalized()
if up.z < 0: up = -up

def aim(obj, target):
    obj.rotation_euler = (target - obj.location).to_track_quat('-Z', 'Y').to_euler()

def softbox(name, location, energy, size):
    light = bpy.data.lights.new(name, 'AREA'); light.energy = energy; light.shape = 'DISK'; light.size = size
    obj = bpy.data.objects.new(name, light); bpy.context.collection.objects.link(obj); obj.location = location; aim(obj, center)

softbox('Key', center + normal * .45 - right * .24 + up * .35, 18, .45)
softbox('Edge', center + normal * .20 + right * .38 + up * .12, 22, .35)
softbox('Fill', center + normal * .30 - up * .25, 6, .4)
world = bpy.data.worlds.new('Studio'); world.use_nodes = True
world.node_tree.nodes['Background'].inputs['Color'].default_value = (.28, .3, .34, 1)
world.node_tree.nodes['Background'].inputs['Strength'].default_value = .35
bpy.context.scene.world = world
camera_data = bpy.data.cameras.new('Camera'); camera_data.type = 'ORTHO'; camera_data.ortho_scale = .62
camera = bpy.data.objects.new('Camera', camera_data); bpy.context.collection.objects.link(camera)
scene = bpy.context.scene; scene.camera = camera; scene.render.engine = 'CYCLES'
scene.cycles.samples = 48; scene.cycles.use_denoising = True
scene.render.resolution_x = 1600; scene.render.resolution_y = 1100; scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'; scene.render.image_settings.color_mode = 'RGBA'; scene.render.film_transparent = True
scene.view_settings.view_transform = 'Standard'
for name, offset in [('ipad-angle-left', -.17), ('ipad-angle-right', .17)]:
    camera.location = center + normal * .65 + right * offset + up * .10
    aim(camera, center - up * .055)
    scene.render.filepath = str(root / f'assets/devices/{name}.png')
    bpy.ops.render.render(write_still=True)
    print('Rendered', scene.render.filepath)
