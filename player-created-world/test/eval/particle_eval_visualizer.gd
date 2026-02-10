extends SceneTree
## Entry point for the particle effect eval visualizer.
##
## This script is designed to be run with Godot's --script flag (NOT headless):
##
##   godot --path player-created-world --script res://test/eval/particle_eval_visualizer.gd
##
## Or via the test runner:
##
##   scripts/run_tests.ps1 -ShowResults
##   scripts/run_tests.ps1 -Mode eval -ShowResults
##   scripts/run_tests.sh --show-results
##
## Controls:
##   ESC   - quit
##   SPACE - replay all effects

const ParticleEvalViewer := preload("res://test/eval/particle_eval_viewer.gd")


func _initialize() -> void:
	root.title = "Particle Effect Eval — Grid Viewer"
	var viewer: Node3D = ParticleEvalViewer.new()
	root.add_child(viewer)
