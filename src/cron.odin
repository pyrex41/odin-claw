package main

import "core:fmt"
import "core:strings"
import "core:strconv"
import "core:time"
import "core:os"

// ============================================================================
// Cron Expression Types
// ============================================================================

// CronExpression holds parsed fields from a standard 5-field cron string.
// An empty dynamic array for a field means wildcard (match all).
CronExpression :: struct {
    minutes:  [dynamic]int,
    hours:    [dynamic]int,
    days:     [dynamic]int,
    months:   [dynamic]int,
    weekdays: [dynamic]int,
}

// CronJob represents a single scheduled job managed by the scheduler.
CronJob :: struct {
    id:       string,
    name:     string,
    schedule: string,
    command:  string,
    enabled:  bool,
    last_run: i64,
    next_run: i64,
}

// CronScheduler manages a collection of cron jobs and drives execution.
CronScheduler :: struct {
    jobs:              [dynamic]CronJob,
    running:           bool,
    check_interval_ms: int,
    next_id:           int,
}

// ============================================================================
// Scheduler Lifecycle
// ============================================================================

// init_cron_scheduler creates and returns a new CronScheduler with defaults.
init_cron_scheduler :: proc() -> ^CronScheduler {
    cs := new(CronScheduler)
    cs.jobs = make([dynamic]CronJob)
    cs.running = false
    cs.check_interval_ms = 60000 // default 1 minute
    cs.next_id = 1
    return cs
}

// deinit_cron_scheduler frees all resources held by the scheduler.
deinit_cron_scheduler :: proc(cs: ^CronScheduler) {
    for &job in cs.jobs {
        delete(job.id)
        delete(job.name)
        delete(job.schedule)
        delete(job.command)
    }
    delete(cs.jobs)
    free(cs)
}

// ============================================================================
// Job Management
// ============================================================================

// add_cron_job registers a new job and returns its unique ID string.
// Returns an empty string if the schedule expression is invalid.
add_cron_job :: proc(cs: ^CronScheduler, name: string, schedule: string, command: string) -> string {
    // Validate the schedule before accepting the job
    expr, ok := parse_cron_expression(schedule)
    if !ok {
        fmt.printf("[Cron] Invalid schedule expression: %s\n", schedule)
        return ""
    }
    deinit_cron_expression(&expr)

    id_str := fmt.aprintf("cron_%d", cs.next_id)
    cs.next_id += 1

    now := time.time_to_unix(time.now())

    job := CronJob{
        id       = id_str,
        name     = strings.clone(name),
        schedule = strings.clone(schedule),
        command  = strings.clone(command),
        enabled  = true,
        last_run = 0,
        next_run = compute_next_run(schedule, now),
    }

    append(&cs.jobs, job)
    fmt.printf("[Cron] Added job '%s' (id=%s, schedule=%s)\n", name, id_str, schedule)

    return strings.clone(id_str)
}

// remove_cron_job deletes a job by ID. Returns true if found and removed.
remove_cron_job :: proc(cs: ^CronScheduler, id: string) -> bool {
    for i := 0; i < len(cs.jobs); i += 1 {
        if cs.jobs[i].id == id {
            job := cs.jobs[i]
            fmt.printf("[Cron] Removed job '%s' (id=%s)\n", job.name, job.id)
            delete(job.id)
            delete(job.name)
            delete(job.schedule)
            delete(job.command)
            ordered_remove(&cs.jobs, i)
            return true
        }
    }
    return false
}

// list_cron_jobs returns a slice view of all current jobs.
list_cron_jobs :: proc(cs: ^CronScheduler) -> []CronJob {
    return cs.jobs[:]
}

// ============================================================================
// Scheduler Control
// ============================================================================

// start_scheduler marks the scheduler as running.
start_scheduler :: proc(cs: ^CronScheduler) {
    if cs.running {
        fmt.printf("[Cron] Scheduler is already running\n")
        return
    }
    cs.running = true
    fmt.printf("[Cron] Scheduler started (check_interval=%dms, jobs=%d)\n",
        cs.check_interval_ms, len(cs.jobs))
}

// stop_scheduler marks the scheduler as stopped.
stop_scheduler :: proc(cs: ^CronScheduler) {
    if !cs.running {
        fmt.printf("[Cron] Scheduler is already stopped\n")
        return
    }
    cs.running = false
    fmt.printf("[Cron] Scheduler stopped\n")
}

// tick_scheduler checks all enabled jobs and executes any that are due.
// The caller is responsible for invoking this periodically (e.g. every
// check_interval_ms from the main loop or daemon).
tick_scheduler :: proc(cs: ^CronScheduler) {
    if !cs.running {
        return
    }

    now_time := time.now()
    now_unix := time.time_to_unix(now_time)

    for &job in cs.jobs {
        if !job.enabled {
            continue
        }

        expr, ok := parse_cron_expression(job.schedule)
        if !ok {
            continue
        }
        defer deinit_cron_expression(&expr)

        if cron_matches(expr, now_time) {
            // Prevent re-execution within the same minute
            if job.last_run > 0 {
                elapsed := now_unix - job.last_run
                if elapsed < 60 {
                    continue
                }
            }

            execute_cron_job(&job)
            job.last_run = now_unix
            job.next_run = compute_next_run(job.schedule, now_unix)
        }
    }
}

// execute_cron_job runs the command associated with a job.
execute_cron_job :: proc(job: ^CronJob) {
    fmt.printf("[Cron] Executing job: %s -> %s\n", job.name, job.command)
    c_cmd := strings.clone_to_cstring(job.command)
    defer delete(c_cmd)
    exit_code := system(c_cmd)
    fmt.printf("[Cron] Job '%s' exit code: %d\n", job.name, exit_code)
}

// ============================================================================
// Cron Expression Parser
// ============================================================================

// parse_cron_expression parses a standard 5-field cron string.
// Fields: minute hour day-of-month month day-of-week
// Supports: * (wildcard), specific numbers, comma-separated lists.
// Returns (CronExpression, true) on success, ({}, false) on failure.
parse_cron_expression :: proc(expr: string) -> (CronExpression, bool) {
    result := CronExpression{
        minutes  = make([dynamic]int),
        hours    = make([dynamic]int),
        days     = make([dynamic]int),
        months   = make([dynamic]int),
        weekdays = make([dynamic]int),
    }

    trimmed := strings.trim_space(expr)
    fields := strings.split(trimmed, " ")
    defer delete(fields)

    // Filter out empty strings that can result from multiple spaces
    non_empty := make([dynamic]string)
    defer delete(non_empty)
    for f in fields {
        if len(f) > 0 {
            append(&non_empty, f)
        }
    }

    if len(non_empty) != 5 {
        deinit_cron_expression(&result)
        return {}, false
    }

    // Parse each field with its valid range
    if !parse_cron_field(non_empty[0], &result.minutes, 0, 59) {
        deinit_cron_expression(&result)
        return {}, false
    }
    if !parse_cron_field(non_empty[1], &result.hours, 0, 23) {
        deinit_cron_expression(&result)
        return {}, false
    }
    if !parse_cron_field(non_empty[2], &result.days, 1, 31) {
        deinit_cron_expression(&result)
        return {}, false
    }
    if !parse_cron_field(non_empty[3], &result.months, 1, 12) {
        deinit_cron_expression(&result)
        return {}, false
    }
    if !parse_cron_field(non_empty[4], &result.weekdays, 0, 6) {
        deinit_cron_expression(&result)
        return {}, false
    }

    return result, true
}

// parse_cron_field parses a single cron field into a dynamic array of ints.
// Wildcard (*) leaves the array empty. Comma-separated values are expanded.
// Each value is validated against min_val..max_val inclusive.
parse_cron_field :: proc(field: string, values: ^[dynamic]int, min_val: int, max_val: int) -> bool {
    if field == "*" {
        // Empty array signals wildcard (match all)
        return true
    }

    parts := strings.split(field, ",")
    defer delete(parts)

    for part in parts {
        trimmed := strings.trim_space(part)
        if len(trimmed) == 0 {
            return false
        }

        val, ok := strconv.parse_int(trimmed)
        if !ok {
            return false
        }

        if val < min_val || val > max_val {
            return false
        }

        append(values, val)
    }

    return len(values^) > 0
}

// deinit_cron_expression frees memory held by a CronExpression.
deinit_cron_expression :: proc(expr: ^CronExpression) {
    delete(expr.minutes)
    delete(expr.hours)
    delete(expr.days)
    delete(expr.months)
    delete(expr.weekdays)
}

// ============================================================================
// Cron Matching
// ============================================================================

// cron_matches checks whether a given time matches a parsed cron expression.
cron_matches :: proc(expr: CronExpression, t: time.Time) -> bool {
    _, month_enum, day := time.date(t)
    hour, minute, _ := time.clock(t)
    weekday := time.weekday(t)

    month := int(month_enum)
    wday := int(weekday) // Sunday=0 in Odin's time package

    if !field_matches(expr.minutes, minute) {
        return false
    }
    if !field_matches(expr.hours, hour) {
        return false
    }
    if !field_matches(expr.days, day) {
        return false
    }
    if !field_matches(expr.months, month) {
        return false
    }
    if !field_matches(expr.weekdays, wday) {
        return false
    }

    return true
}

// field_matches returns true if the value matches the cron field.
// An empty array means wildcard (matches everything).
field_matches :: proc(allowed: [dynamic]int, value: int) -> bool {
    if len(allowed) == 0 {
        return true // wildcard
    }
    for v in allowed {
        if v == value {
            return true
        }
    }
    return false
}

// ============================================================================
// Next Run Computation
// ============================================================================

// compute_next_run estimates the next unix timestamp when the job should fire.
// Scans forward minute-by-minute from the given base time, up to 48 hours.
compute_next_run :: proc(schedule: string, base_unix: i64) -> i64 {
    expr, ok := parse_cron_expression(schedule)
    if !ok {
        return 0
    }
    defer deinit_cron_expression(&expr)

    // Start from the next full minute after base
    start := base_unix - (base_unix % 60) + 60
    max_attempts := 2880 // 48 hours worth of minutes

    for i := 0; i < max_attempts; i += 1 {
        candidate_unix := start + i64(i * 60)
        candidate_time := time.unix(candidate_unix, 0)

        if cron_matches(expr, candidate_time) {
            return candidate_unix
        }
    }

    // Fallback: schedule for base + 60s
    return base_unix + 60
}

// ============================================================================
// Serialization Helpers
// ============================================================================

// serialize_cron_jobs produces a JSON array string of all jobs.
serialize_cron_jobs :: proc(cs: ^CronScheduler) -> string {
    sb := strings.builder_make()
    strings.write_string(&sb, "[")

    for i := 0; i < len(cs.jobs); i += 1 {
        if i > 0 {
            strings.write_string(&sb, ",")
        }
        job := cs.jobs[i]

        escaped_name := escape_json_string(job.name)
        defer delete(escaped_name)
        escaped_cmd := escape_json_string(job.command)
        defer delete(escaped_cmd)

        strings.write_string(&sb, "{")
        strings.write_string(&sb, fmt.tprintf(`"id":"%s"`, job.id))
        strings.write_string(&sb, fmt.tprintf(`,"name":"%s"`, escaped_name))
        strings.write_string(&sb, fmt.tprintf(`,"schedule":"%s"`, job.schedule))
        strings.write_string(&sb, fmt.tprintf(`,"command":"%s"`, escaped_cmd))
        strings.write_string(&sb, fmt.tprintf(`,"enabled":%s`, job.enabled ? "true" : "false"))
        strings.write_string(&sb, fmt.tprintf(`,"last_run":%d`, job.last_run))
        strings.write_string(&sb, fmt.tprintf(`,"next_run":%d`, job.next_run))
        strings.write_string(&sb, "}")
    }

    strings.write_string(&sb, "]")
    return strings.to_string(sb)
}

// ============================================================================
// Utility Procedures
// ============================================================================

// enable_cron_job enables a job by ID. Returns true if found.
enable_cron_job :: proc(cs: ^CronScheduler, id: string) -> bool {
    for &job in cs.jobs {
        if job.id == id {
            job.enabled = true
            fmt.printf("[Cron] Enabled job '%s' (id=%s)\n", job.name, job.id)
            return true
        }
    }
    return false
}

// disable_cron_job disables a job by ID. Returns true if found.
disable_cron_job :: proc(cs: ^CronScheduler, id: string) -> bool {
    for &job in cs.jobs {
        if job.id == id {
            job.enabled = false
            fmt.printf("[Cron] Disabled job '%s' (id=%s)\n", job.name, job.id)
            return true
        }
    }
    return false
}

// get_cron_job_by_id looks up a single job by its ID.
// Returns a pointer to the job if found, nil otherwise.
get_cron_job_by_id :: proc(cs: ^CronScheduler, id: string) -> ^CronJob {
    for &job in cs.jobs {
        if job.id == id {
            return &job
        }
    }
    return nil
}

// print_cron_status logs a summary of the scheduler state.
print_cron_status :: proc(cs: ^CronScheduler) {
    enabled_count := 0
    for job in cs.jobs {
        if job.enabled {
            enabled_count += 1
        }
    }
    fmt.printf("[Cron] Status: running=%s, total_jobs=%d, enabled=%d, interval=%dms\n",
        cs.running ? "true" : "false", len(cs.jobs), enabled_count, cs.check_interval_ms)
}

// print_cron_jobs logs details for each registered job.
print_cron_jobs :: proc(cs: ^CronScheduler) {
    if len(cs.jobs) == 0 {
        fmt.printf("[Cron] No jobs registered\n")
        return
    }

    fmt.printf("[Cron] Registered jobs (%d):\n", len(cs.jobs))
    for job in cs.jobs {
        fmt.printf("  [%s] %s | schedule=%s | enabled=%s | last_run=%d | next_run=%d\n",
            job.id, job.name, job.schedule,
            job.enabled ? "yes" : "no",
            job.last_run, job.next_run)
    }
}

// reschedule_all_jobs recomputes next_run for every enabled job.
reschedule_all_jobs :: proc(cs: ^CronScheduler) {
    now := time.time_to_unix(time.now())
    for &job in cs.jobs {
        if job.enabled {
            job.next_run = compute_next_run(job.schedule, now)
        }
    }
    fmt.printf("[Cron] Rescheduled %d jobs\n", len(cs.jobs))
}

// clear_all_jobs removes every job from the scheduler.
clear_all_jobs :: proc(cs: ^CronScheduler) {
    for &job in cs.jobs {
        delete(job.id)
        delete(job.name)
        delete(job.schedule)
        delete(job.command)
    }
    clear(&cs.jobs)
    fmt.printf("[Cron] All jobs cleared\n")
}
