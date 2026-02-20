package main

import "core:fmt"
import "core:strings"
import "core:time"

// MetricsCollector holds counters, gauges, and histograms for Prometheus-compatible
// metrics exposition. Keys are simple strings like "requests_total".
MetricsCollector :: struct {
	counters:   map[string]i64,
	gauges:     map[string]f64,
	histograms: map[string][dynamic]f64,
	start_time: i64,
}

// init_metrics creates and returns a new MetricsCollector with all maps initialized.
init_metrics :: proc() -> ^MetricsCollector {
	mc := new(MetricsCollector)
	mc.counters = make(map[string]i64)
	mc.gauges = make(map[string]f64)
	mc.histograms = make(map[string][dynamic]f64)
	mc.start_time = time.time_to_unix(time.now())
	return mc
}

// deinit_metrics frees all maps, dynamic arrays, and cloned keys.
deinit_metrics :: proc(mc: ^MetricsCollector) {
	for key in mc.counters {
		delete(key)
	}
	delete(mc.counters)

	for key in mc.gauges {
		delete(key)
	}
	delete(mc.gauges)

	for key, &obs in mc.histograms {
		delete(obs)
		delete(key)
	}
	delete(mc.histograms)

	free(mc)
}

// inc_counter increments a counter by 1.
inc_counter :: proc(mc: ^MetricsCollector, name: string) {
	inc_counter_by(mc, name, 1)
}

// inc_counter_by increments a counter by the given delta.
inc_counter_by :: proc(mc: ^MetricsCollector, name: string, delta: i64) {
	if name in mc.counters {
		mc.counters[name] += delta
	} else {
		cloned := strings.clone(name)
		mc.counters[cloned] = delta
	}
}

// set_gauge sets a gauge to the given value.
set_gauge :: proc(mc: ^MetricsCollector, name: string, value: f64) {
	if name in mc.gauges {
		mc.gauges[name] = value
	} else {
		cloned := strings.clone(name)
		mc.gauges[cloned] = value
	}
}

// observe_histogram records a single observation for a histogram metric.
observe_histogram :: proc(mc: ^MetricsCollector, name: string, value: f64) {
	if name in mc.histograms {
		append(&mc.histograms[name], value)
	} else {
		cloned := strings.clone(name)
		obs := make([dynamic]f64)
		append(&obs, value)
		mc.histograms[cloned] = obs
	}
}

// format_prometheus formats all collected metrics in the Prometheus text exposition format.
// The caller is responsible for freeing the returned string.
format_prometheus :: proc(mc: ^MetricsCollector) -> string {
	sb := strings.builder_make()

	// Uptime gauge (seconds since start)
	now := time.time_to_unix(time.now())
	uptime := now - mc.start_time
	strings.write_string(&sb, "# TYPE uptime_seconds gauge\n")
	strings.write_string(&sb, fmt.tprintf("uptime_seconds %d\n", uptime))

	// Counters
	for name, value in mc.counters {
		strings.write_string(&sb, fmt.tprintf("# TYPE %s counter\n", name))
		strings.write_string(&sb, fmt.tprintf("%s %d\n", name, value))
	}

	// Gauges
	for name, value in mc.gauges {
		strings.write_string(&sb, fmt.tprintf("# TYPE %s gauge\n", name))
		strings.write_string(&sb, fmt.tprintf("%s %g\n", name, value))
	}

	// Histograms — emit _sum and _count for each
	for name, observations in mc.histograms {
		strings.write_string(&sb, fmt.tprintf("# TYPE %s histogram\n", name))

		sum: f64 = 0
		for v in observations {
			sum += v
		}
		count := len(observations)

		strings.write_string(&sb, fmt.tprintf("%s_sum %g\n", name, sum))
		strings.write_string(&sb, fmt.tprintf("%s_count %d\n", name, count))
	}

	return strings.to_string(sb)
}

// format_json_metrics formats all collected metrics as a JSON object for the /metrics API.
// The caller is responsible for freeing the returned string.
format_json_metrics :: proc(mc: ^MetricsCollector) -> string {
	sb := strings.builder_make()

	now := time.time_to_unix(time.now())
	uptime := now - mc.start_time

	strings.write_string(&sb, "{")

	strings.write_string(&sb, fmt.tprintf(`"uptime_seconds":%d`, uptime))

	// Counters
	strings.write_string(&sb, `,"counters":{`)
	counter_idx := 0
	for name, value in mc.counters {
		if counter_idx > 0 {
			strings.write_string(&sb, ",")
		}
		strings.write_string(&sb, fmt.tprintf(`"%s":%d`, name, value))
		counter_idx += 1
	}
	strings.write_string(&sb, "}")

	// Gauges
	strings.write_string(&sb, `,"gauges":{`)
	gauge_idx := 0
	for name, value in mc.gauges {
		if gauge_idx > 0 {
			strings.write_string(&sb, ",")
		}
		strings.write_string(&sb, fmt.tprintf(`"%s":%g`, name, value))
		gauge_idx += 1
	}
	strings.write_string(&sb, "}")

	// Histograms
	strings.write_string(&sb, `,"histograms":{`)
	hist_idx := 0
	for name, observations in mc.histograms {
		if hist_idx > 0 {
			strings.write_string(&sb, ",")
		}

		sum: f64 = 0
		for v in observations {
			sum += v
		}
		count := len(observations)

		strings.write_string(&sb, fmt.tprintf(`"%s":{"sum":%g,"count":%d}`, name, sum, count))
		hist_idx += 1
	}
	strings.write_string(&sb, "}")

	strings.write_string(&sb, "}")
	return strings.to_string(sb)
}

// reset_metrics clears all counters, gauges, and histograms but preserves the start time.
reset_metrics :: proc(mc: ^MetricsCollector) {
	for key in mc.counters {
		delete(key)
	}
	delete(mc.counters)
	mc.counters = make(map[string]i64)

	for key in mc.gauges {
		delete(key)
	}
	delete(mc.gauges)
	mc.gauges = make(map[string]f64)

	for key, &obs in mc.histograms {
		delete(obs)
		delete(key)
	}
	delete(mc.histograms)
	mc.histograms = make(map[string][dynamic]f64)
}

// ============================================================================
// Convenience Procedures
// ============================================================================

// record_api_call tracks an API call to a provider, recording the call count,
// duration histogram, and error count when the call was not successful.
record_api_call :: proc(mc: ^MetricsCollector, provider: string, duration_ms: f64, success: bool) {
	// Increment per-provider call count
	call_key := fmt.tprintf("api_calls_%s_total", provider)
	inc_counter(mc, call_key)

	// Record duration in the histogram
	duration_key := fmt.tprintf("api_duration_%s_ms", provider)
	observe_histogram(mc, duration_key, duration_ms)

	// Track errors
	if !success {
		error_key := fmt.tprintf("api_errors_%s_total", provider)
		inc_counter(mc, error_key)
	}

	// Also bump the aggregate counters
	inc_counter(mc, "api_calls_total")
	observe_histogram(mc, "api_duration_ms", duration_ms)
	if !success {
		inc_counter(mc, "api_errors_total")
	}
}

// record_message increments the per-channel message count and the global message total.
record_message :: proc(mc: ^MetricsCollector, channel: string) {
	channel_key := fmt.tprintf("messages_%s_total", channel)
	inc_counter(mc, channel_key)
	inc_counter(mc, "messages_total")
}
