class_name GdUnitTestSuite
extends RefCounted

var _gdunit_reporter: Object = null

func _set_reporter(reporter: Object) -> void:
	_gdunit_reporter = reporter

func _report_failure(message: String) -> void:
	if _gdunit_reporter != null and _gdunit_reporter.has_method("record_failure"):
		_gdunit_reporter.record_failure(message)

func assert_true(value: bool, message: String = "") -> void:
	if not value:
		_report_failure(message if message != "" else "Expected true but got false.")

func assert_false(value: bool, message: String = "") -> void:
	if value:
		_report_failure(message if message != "" else "Expected false but got true.")

func assert_eq(expected, actual, message: String = "") -> void:
	if expected != actual:
		var detail := "Expected %s but got %s." % [str(expected), str(actual)]
		_report_failure(message if message != "" else detail)

func assert_ne(unexpected, actual, message: String = "") -> void:
	if unexpected == actual:
		var detail := "Did not expect %s but got it." % [str(actual)]
		_report_failure(message if message != "" else detail)

func assert_gt(left, right, message: String = "") -> void:
	if not (left > right):
		var detail := "Expected %s to be greater than %s." % [str(left), str(right)]
		_report_failure(message if message != "" else detail)

func assert_lt(left, right, message: String = "") -> void:
	if not (left < right):
		var detail := "Expected %s to be less than %s." % [str(left), str(right)]
		_report_failure(message if message != "" else detail)

func fail(message: String) -> void:
	_report_failure(message if message != "" else "Test failed.")
