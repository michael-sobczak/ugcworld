extends Node3D

var particles: GPUParticles3D
var timer: Timer
var mat: ParticleProcessMaterial
var mesh: QuadMesh

func _ready() -> void:
    particles = GPUParticles3D.new()
    timer = Timer.new()
    mat = ParticleProcessMaterial.new()
    mesh = QuadMesh.new()

    add_child(particles)
    add_child(timer)

    particles.amount = 64
    particles.lifetime = 2.0
    particles.one_shot = true
    particles.emitting = false
    particles.explosiveness = 1.0
    particles.process_material = mat
    particles.draw_pass_1 = mesh

    mat.direction = Vector3(0.0, 1.0, 0.0)
    mat.spread = 45.0
    mat.initial_velocity_min = 5.0
    mat.initial_velocity_max = 10.0
    mat.gravity = Vector3(0.0, -4.8, 0.0)
    mat.scale_min = 0.1
    mat.scale_max = 0.3

    var grad := Gradient.new()
    grad.colors = PackedColorArray([Color(1, 0.8, 0.6, 1), Color(1, 0.1, 0.1, 0)])
    grad.offsets = PackedFloat32Array([0.0, 1.0])
    var grad_tex := GradientTexture1D.new()
    grad_tex.gradient = grad
    mat.color_ramp = grad_tex

    var mesh_mat := StandardMaterial3D.new()
    mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mesh_mat.vertex_color_use_as_albedo = true
    mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    mesh_mat.albedo_texture = _create_texture()
    mesh.material = mesh_mat
    mesh.size = Vector2(0.2, 0.2)

    timer.one_shot = true
    timer.wait_time = particles.lifetime + 0.5
    timer.timeout.connect(queue_free)

func play_at(pos: Vector3, dir: Vector3 = Vector3.ZERO) -> void:
    global_position = pos
    if dir != Vector3.ZERO:
        mat.direction = dir.normalized()
    particles.emitting = true
    timer.start()

func _create_texture() -> ImageTexture:
    var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
    for y in range(32):
        for x in range(32):
            var d: float = Vector2(x, y).distance_to(Vector2(16, 16))
            var a: float = clampf(1.0 - d / 16.0, 0.0, 1.0)
            img.set_pixel(x, y, Color(1.0, d / 32.0, 0.0, a))
    return ImageTexture.create_from_image(img)