package main

import "core:testing"

// Tests for provider functionality

@test
test_compatible_endpoint_detection :: proc(t: ^testing.T) {
    testing.expect(t, get_compatible_endpoint("groq") == "https://api.groq.com/openai", "Groq endpoint")
    testing.expect(t, get_compatible_endpoint("deepseek") == "https://api.deepseek.com", "DeepSeek endpoint")
    testing.expect(t, get_compatible_endpoint("ollama") == "http://localhost:11434/v1", "Ollama endpoint")
    testing.expect(t, get_compatible_endpoint("lmstudio") == "http://localhost:1234/v1", "LM Studio endpoint")
    testing.expect(t, get_compatible_endpoint("zen") == "https://api.opencode.ai", "Zen endpoint")
    testing.expect(t, get_compatible_endpoint("unknown") == "", "Unknown returns empty")
}

@test
test_provider_type_detection :: proc(t: ^testing.T) {
    testing.expect(t, get_provider_type("openai", "sk-test") == .OpenAI, "OpenAI by name")
    testing.expect(t, get_provider_type("anthropic", "sk-ant-test") == .Anthropic, "Anthropic by name")
    testing.expect(t, get_provider_type("ollama", "") == .Ollama, "Ollama by name")
    testing.expect(t, get_provider_type("groq", "gsk_test") == .Compatible, "Groq by key prefix")
    testing.expect(t, get_provider_type("deepseek", "sk-test") == .Compatible, "DeepSeek by endpoint")
}

@test
test_classify_provider_by_key :: proc(t: ^testing.T) {
    testing.expect(t, classify_provider_by_key("gsk_abc") == .Compatible, "gsk_ prefix = Compatible")
    testing.expect(t, classify_provider_by_key("xai-abc") == .Compatible, "xai- prefix = Compatible")
    testing.expect(t, classify_provider_by_key("pplx-abc") == .Compatible, "pplx- prefix = Compatible")
    testing.expect(t, classify_provider_by_key("AKIAIOSFODNN7EXAMPLE") == .Compatible, "AWS key = Compatible")
    testing.expect(t, classify_provider_by_key("sk-test") == .OpenAI, "sk- prefix = OpenAI")
}