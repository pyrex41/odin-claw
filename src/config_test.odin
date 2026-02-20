package main

import "core:testing"

// Tests for config functionality

@test
test_validate_valid_config :: proc(t: ^testing.T) {
    config := default_config()
    testing.expect(t, validate(config), "Default config should pass validation")
}

@test
test_validate_invalid_config :: proc(t: ^testing.T) {
    config := Config{} // all zero, invalid
    testing.expect(t, !validate(config), "Invalid config should fail validation")
}