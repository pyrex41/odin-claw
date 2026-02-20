package main

import "core:fmt"
import "core:strings"

// UsageInfo tracks token usage from a single API call
UsageInfo :: struct {
    input_tokens:  int,
    output_tokens: int,
    total_tokens:  int,
}

// CostTracker accumulates usage across a session
CostTracker :: struct {
    total_input_tokens:  int,
    total_output_tokens: int,
    total_calls:         int,
    budget_limit:        f64, // max cost in USD, 0 = unlimited
    model_name:          string,
}

init_cost_tracker :: proc(budget_limit: f64) -> ^CostTracker {
    ct := new(CostTracker)
    ct.budget_limit = budget_limit
    return ct
}

deinit_cost_tracker :: proc(ct: ^CostTracker) {
    free(ct)
}

// record_usage adds token counts from an API response
record_usage :: proc(ct: ^CostTracker, usage: UsageInfo) {
    ct.total_input_tokens += usage.input_tokens
    ct.total_output_tokens += usage.output_tokens
    ct.total_calls += 1
}

// estimate_cost returns estimated cost in USD based on model pricing
estimate_cost :: proc(ct: ^CostTracker, model: string) -> f64 {
    // Pricing per 1M tokens (approximate, as of 2024/2025)
    input_price: f64
    output_price: f64

    if strings.contains(model, "gpt-4o") {
        input_price = 2.50   // $2.50/1M input
        output_price = 10.00 // $10/1M output
    } else if strings.contains(model, "gpt-4") {
        input_price = 30.00
        output_price = 60.00
    } else if strings.contains(model, "gpt-3.5") {
        input_price = 0.50
        output_price = 1.50
    } else if strings.contains(model, "claude-3-5-sonnet") || strings.contains(model, "claude-sonnet") {
        input_price = 3.00
        output_price = 15.00
    } else if strings.contains(model, "claude-opus") {
        input_price = 15.00
        output_price = 75.00
    } else if strings.contains(model, "claude-haiku") {
        input_price = 0.25
        output_price = 1.25
    } else if strings.contains(model, "gemini") {
        input_price = 0.075  // Gemini Flash is very cheap
        output_price = 0.30
    } else if strings.contains(model, "grok") {
        input_price = 5.00
        output_price = 15.00
    } else if strings.contains(model, "llama") || strings.contains(model, "mixtral") {
        input_price = 0.27   // Groq pricing
        output_price = 0.27
    } else {
        // Default estimate
        input_price = 1.00
        output_price = 3.00
    }

    input_cost := f64(ct.total_input_tokens) / 1_000_000.0 * input_price
    output_cost := f64(ct.total_output_tokens) / 1_000_000.0 * output_price
    return input_cost + output_cost
}

// is_over_budget checks if the estimated cost exceeds the budget
is_over_budget :: proc(ct: ^CostTracker, model: string) -> bool {
    if ct.budget_limit <= 0 {
        return false
    }
    return estimate_cost(ct, model) >= ct.budget_limit
}

// format_usage returns a human-readable usage summary
format_usage :: proc(ct: ^CostTracker, model: string) -> string {
    cost := estimate_cost(ct, model)
    return fmt.tprintf("Usage: %d calls, %d input tokens, %d output tokens, est. $%.4f",
        ct.total_calls, ct.total_input_tokens, ct.total_output_tokens, cost)
}

// parse_usage_from_openai extracts usage info from an OpenAI API response
parse_usage_from_openai :: proc(body: string) -> UsageInfo {
    usage: UsageInfo

    // Find "usage" object
    usage_idx := strings.index(body, `"usage"`)
    if usage_idx < 0 {
        return usage
    }

    region := body[usage_idx:]

    // Parse prompt_tokens
    if pt_idx := strings.index(region, `"prompt_tokens"`); pt_idx >= 0 {
        usage.input_tokens = parse_json_int_value(region[pt_idx:], "prompt_tokens")
    }

    // Parse completion_tokens
    if ct_idx := strings.index(region, `"completion_tokens"`); ct_idx >= 0 {
        usage.output_tokens = parse_json_int_value(region[ct_idx:], "completion_tokens")
    }

    // Parse total_tokens
    if tt_idx := strings.index(region, `"total_tokens"`); tt_idx >= 0 {
        usage.total_tokens = parse_json_int_value(region[tt_idx:], "total_tokens")
    }

    if usage.total_tokens == 0 {
        usage.total_tokens = usage.input_tokens + usage.output_tokens
    }

    return usage
}

// parse_usage_from_anthropic extracts usage info from an Anthropic API response
parse_usage_from_anthropic :: proc(body: string) -> UsageInfo {
    usage: UsageInfo

    usage_idx := strings.index(body, `"usage"`)
    if usage_idx < 0 {
        return usage
    }

    region := body[usage_idx:]

    if it_idx := strings.index(region, `"input_tokens"`); it_idx >= 0 {
        usage.input_tokens = parse_json_int_value(region[it_idx:], "input_tokens")
    }

    if ot_idx := strings.index(region, `"output_tokens"`); ot_idx >= 0 {
        usage.output_tokens = parse_json_int_value(region[ot_idx:], "output_tokens")
    }

    usage.total_tokens = usage.input_tokens + usage.output_tokens
    return usage
}

// parse_json_int_value extracts an integer value from "key":123 pattern
parse_json_int_value :: proc(region: string, key: string) -> int {
    search := fmt.tprintf(`"%s":`, key)
    idx := strings.index(region, search)
    if idx < 0 {
        return 0
    }

    pos := idx + len(search)
    // Skip whitespace
    for pos < len(region) && (region[pos] == ' ' || region[pos] == '\t') {
        pos += 1
    }

    // Read digits
    result := 0
    for pos < len(region) && region[pos] >= '0' && region[pos] <= '9' {
        result = result * 10 + int(region[pos] - '0')
        pos += 1
    }
    return result
}
