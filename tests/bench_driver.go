// Standalone standard-library backend/load generator for compare.py.
// This is test tooling; it is not linked into Vaddy.
package main

import (
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	mode := flag.String("mode", "load", "backend or load")
	addr := flag.String("listen", "127.0.0.1:0", "backend address")
	url := flag.String("url", "", "target URL")
	concurrency := flag.Int("concurrency", 1, "parallel clients")
	seconds := flag.Float64("seconds", 10, "duration")
	size := flag.Int("size", 512, "response body bytes")
	flag.Parse()
	if *mode == "backend" {
		body := []byte(strings.Repeat("x", *size))
		listener, err := net.Listen("tcp", *addr)
		if err != nil {
			panic(err)
		}
		fmt.Println(listener.Addr().String())
		err = http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/static/assets/bench.js" {
				http.Error(w, "rewrite failed", 500)
				return
			}
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.Header().Set("Cross-Origin-Embedder-Policy", "require-corp")
			w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
			w.Write(body)
		}))
		if err != nil {
			panic(err)
		}
		return
	}
	if *concurrency < 1 || *seconds <= 0 || *url == "" {
		flag.Usage()
		os.Exit(2)
	}
	transport := &http.Transport{
		Proxy: nil, DisableCompression: true,
		MaxIdleConns: *concurrency, MaxIdleConnsPerHost: *concurrency,
		MaxConnsPerHost: *concurrency, ForceAttemptHTTP2: false,
		// Benchmark-generated self-signed certificate only; no production credentials.
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, NextProtos: []string{"http/1.1"}},
	}
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	var ok, failed, totalNS atomic.Int64
	var firstError string
	var firstErrorOnce sync.Once
	recordError := func(message string) {
		failed.Add(1)
		firstErrorOnce.Do(func() { firstError = message })
	}
	start := time.Now()
	deadline := start.Add(time.Duration(*seconds * float64(time.Second)))
	var workers sync.WaitGroup
	for i := 0; i < *concurrency; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for time.Now().Before(deadline) {
				t := time.Now()
				response, err := client.Get(*url)
				if err != nil {
					recordError(err.Error())
					time.Sleep(time.Millisecond)
					continue
				}
				n, err := io.Copy(io.Discard, response.Body)
				response.Body.Close()
				if err != nil || response.StatusCode != 200 || n != int64(*size) || response.Header.Get("Cross-Origin-Embedder-Policy") != "" || response.Header.Get("Cross-Origin-Opener-Policy") != "" {
					recordError(fmt.Sprintf("status=%d bytes=%d body_error=%v COEP=%q COOP=%q", response.StatusCode, n, err, response.Header.Get("Cross-Origin-Embedder-Policy"), response.Header.Get("Cross-Origin-Opener-Policy")))
					continue
				}
				ok.Add(1)
				totalNS.Add(time.Since(t).Nanoseconds())
			}
		}()
	}
	workers.Wait()
	elapsed := time.Since(start).Seconds()
	transport.CloseIdleConnections()
	mean := 0.0
	if ok.Load() > 0 {
		mean = float64(totalNS.Load()) / float64(ok.Load()) / 1e6
	}
	result := map[string]any{
		"requests": ok.Load(), "errors": failed.Load(), "wall_seconds": elapsed,
		"requests_per_second": float64(ok.Load()) / elapsed, "mean_latency_ms": mean,
	}
	if firstError != "" {
		result["first_error"] = firstError
	}
	json.NewEncoder(os.Stdout).Encode(result)
}
