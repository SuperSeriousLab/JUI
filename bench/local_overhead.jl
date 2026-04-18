# Copyright 2026 eidos workspace
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# ── bench/local_overhead.jl ───────────────────────────────────────────────
# Benchmark Unix socket (JUI local transport) vs stdlib TCPSocket localhost.
#
# Target: Unix socket latency should be within 2x of bare TCP (typically
# 20-100µs range for loopback). Verifies JUI transport overhead is minimal.
#
# Measured results (2026-04-17, Linux 6.8.0, Julia 1.11.5):
#   Unix socket p50: 9.2µs  p95: 9.6µs  p99: 13.3µs
#   TCP loopback p50: 13.3µs  p95: 13.7µs  p99: 18.0µs
#   Ratio: 0.69x — Unix is FASTER than TCP on this kernel. Result: PASS
#   (Unix sockets skip TCP stack entirely; kernel path is shorter on Linux 6.8)
#
# Implementation note: each roundtrip writes payload+newline as a SINGLE
# write() call. Two-arg write(sock, payload, "\n") triggers two syscalls,
# activating Nagle's algorithm on TCP and inflating latency to ~41ms.
# We pre-concat the newline into the payload string to avoid this artefact.
# ─────────────────────────────────────────────────────────────────────────

using JUI
using Sockets
using Statistics

const N = 1000
const PAYLOAD_LINE = "a" ^ 128 * "\n"   # single write — avoids Nagle on TCP

function bench_unix()
    tmpdir = mktempdir()
    withenv("XDG_RUNTIME_DIR" => tmpdir) do
        srv = start_unix_server("bench-sid", sock -> begin
            for _ in 1:N
                line = readline(sock)
                write(sock, line * "\n")
            end
            close(sock)
        end)
        sleep(0.1)
        client = connect_unix("bench-sid")
        times = Float64[]
        for _ in 1:N
            t0 = time_ns()
            write(client, PAYLOAD_LINE)
            readline(client)
            push!(times, (time_ns() - t0) / 1000)  # microseconds
        end
        close(client)
        stop_unix_server!(srv)
        return times
    end
end

function bench_tcp_bare()
    # Raw TCP on loopback for comparison baseline
    port = 14567
    srv = listen(ip"127.0.0.1", port)
    task = @async begin
        sock = accept(srv)
        for _ in 1:N
            line = readline(sock)
            write(sock, line * "\n")
        end
        close(sock)
    end
    sleep(0.1)
    client = connect(ip"127.0.0.1", port)
    times = Float64[]
    for _ in 1:N
        t0 = time_ns()
        write(client, PAYLOAD_LINE)
        readline(client)
        push!(times, (time_ns() - t0) / 1000)
    end
    close(client)
    close(srv)
    wait(task)
    return times
end

function main()
    println("=== JUI local transport overhead benchmark ===")
    println("N=$N roundtrips, payload=$(length(PAYLOAD_LINE)-1) bytes (+newline, single write)")

    unix_times = bench_unix()
    tcp_times  = bench_tcp_bare()

    println("\nUnix socket (JUI transport):")
    println("  p50: $(round(median(unix_times), digits=1))µs")
    println("  p95: $(round(quantile(unix_times, 0.95), digits=1))µs")
    println("  p99: $(round(quantile(unix_times, 0.99), digits=1))µs")

    println("\nTCP loopback (baseline):")
    println("  p50: $(round(median(tcp_times), digits=1))µs")
    println("  p95: $(round(quantile(tcp_times, 0.95), digits=1))µs")
    println("  p99: $(round(quantile(tcp_times, 0.99), digits=1))µs")

    ratio = median(unix_times) / median(tcp_times)
    println("\nUnix/TCP p50 ratio: $(round(ratio, digits=2))x")
    if ratio < 2.0
        println("✓ Within acceptable overhead (< 2x TCP baseline)")
    else
        println("⚠ Unix socket slower than expected")
    end

    return (unix_p50=median(unix_times), tcp_p50=median(tcp_times), ratio=ratio)
end

main()
