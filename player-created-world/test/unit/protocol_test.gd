extends GdUnitTestSuite

func test_vec3_roundtrip() -> void:
	var vec := Vector3(1.234, -5.678, 9.1011)
	var arr := Protocol._vec3_to_array(vec)
	assert_eq(3, arr.size(), "Vector3 should serialize to length 3.")
	var restored := Protocol._array_to_vec3(arr)
	assert_true(restored.is_equal_approx(Vector3(1.234, -5.678, 9.101)), "Vector3 roundtrip should be approx.")

func test_encode_decode_roundtrip() -> void:
	var message := Protocol.build_ping(123.456)
	var json := Protocol.encode_message(message)
	var decoded := Protocol.decode_message(json)
	assert_eq(int(message["type"]), int(decoded["type"]))
	assert_eq(float(message["client_time"]), float(decoded["client_time"]))

func test_entity_state_roundtrip() -> void:
	var state := Protocol.serialize_entity_state(
		42,
		Protocol.EntityType.PLAYER,
		Vector3(2, 3, 4),
		Vector3(0.1, 0.2, 0.3),
		Vector3(5, 6, 7),
		88.0,
		{"team": "blue"}
	)
	var restored := Protocol.deserialize_entity_state(state)
	assert_eq(42, restored["entity_id"])
	assert_eq(Protocol.EntityType.PLAYER, restored["entity_type"])
	assert_true(restored["position"].is_equal_approx(Vector3(2, 3, 4)))
	assert_eq("blue", restored["extra"]["team"])
