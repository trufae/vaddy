// Separate-process socket-pair TLS benchmark; no listening socket is required.
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func pair() (*os.File, net.Conn) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		panic(err)
	}
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	server := os.NewFile(uintptr(fds[0]), "server")
	peer := os.NewFile(uintptr(fds[1]), "peer")
	conn, err := net.FileConn(peer)
	peer.Close()
	if err != nil {
		panic(err)
	}
	return server, conn
}

func main() {
	serverPath := flag.String("server", "", "Vaddy fixture executable")
	size := flag.Int("size", 512, "response bytes")
	workers := flag.Int("workers", 1, "reactor workers")
	clients := flag.Int("clients", 32, "concurrent clients")
	duration := flag.Duration("duration", 5*time.Second, "load duration")
	cert := flag.String("cert", "-", "certificate, or - for plaintext")
	key := flag.String("key", "-", "private key")
	flag.Parse()
	var files []*os.File
	var fronts, backs []net.Conn
	for i := 0; i < *clients; i++ {
		front, client := pair()
		back, backend := pair()
		files = append(files, front, back)
		fronts = append(fronts, client)
		backs = append(backs, backend)
	}
	cmd := exec.Command(*serverPath, strconv.Itoa(*clients), strconv.Itoa(*workers), *cert, *key)
	cmd.ExtraFiles = files
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	for _, file := range files {
		file.Close()
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	response := "HTTP/1.1 200 OK\r\nContent-Length: " + strconv.Itoa(*size) + "\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Opener-Policy: same-origin\r\n\r\n" + strings.Repeat("x", *size)
	for _, backend := range backs {
		go func(conn net.Conn) {
			defer conn.Close()
			reader := bufio.NewReader(conn)
			for {
				request, err := http.ReadRequest(reader)
				if err != nil {
					return
				}
				request.Body.Close()
				if request.URL.Path != "/static/assets/bench.js" {
					panic("rewrite failed")
				}
				if _, err = io.WriteString(conn, response); err != nil {
					return
				}
			}
		}(backend)
	}
	// Complete all handshakes before releasing the load barrier.
	ready := make(chan struct{})
	var started, finished sync.WaitGroup
	var requests, failures atomic.Int64
	var deadline time.Time
	started.Add(*clients)
	finished.Add(*clients)
	for _, front := range fronts {
		go func(conn net.Conn) {
			defer finished.Done()
			conn.SetDeadline(time.Now().Add(*duration + 30*time.Second))
			if *cert != "-" {
				secure := tls.Client(conn, &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, ServerName: "localhost"})
				if err := secure.Handshake(); err != nil {
					panic(err)
				}
				conn = secure
			}
			reader := bufio.NewReader(conn)
			started.Done()
			<-ready
			for time.Now().Before(deadline) {
				if _, err := io.WriteString(conn, "GET /assets/bench.js HTTP/1.1\r\nHost: localhost\r\n\r\n"); err != nil {
					failures.Add(1)
					return
				}
				response, err := http.ReadResponse(reader, nil)
				if err != nil {
					failures.Add(1)
					return
				}
				n, err := io.Copy(io.Discard, response.Body)
				response.Body.Close()
				if err != nil || n != int64(*size) || response.StatusCode != 200 || response.Header.Get("Cross-Origin-Embedder-Policy") != "" || response.Header.Get("Cross-Origin-Opener-Policy") != "" {
					failures.Add(1)
					return
				}
				requests.Add(1)
			}
		}(front)
	}
	started.Wait()
	start := time.Now()
	deadline = start.Add(*duration)
	close(ready)
	finished.Wait()
	elapsed := time.Since(start).Seconds()
	for _, conn := range fronts {
		conn.Close()
	}
	cmd.Process.Signal(syscall.SIGTERM)
	if err := cmd.Wait(); err != nil {
		panic(fmt.Sprintf("server: %v", err))
	}
	usage := cmd.ProcessState.SysUsage().(*syscall.Rusage)
	cpu := cmd.ProcessState.UserTime().Seconds() + cmd.ProcessState.SystemTime().Seconds()
	rss := float64(usage.Maxrss)
	if runtime.GOOS != "darwin" {
		rss *= 1024
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{
		"response_bytes": *size, "workers": *workers, "clients": *clients, "tls": *cert != "-",
		"requests": requests.Load(), "errors": failures.Load(), "wall_seconds": elapsed,
		"requests_per_second": float64(requests.Load()) / elapsed,
		"server_cpu_seconds":  cpu, "server_cpu_us_per_request": cpu * 1e6 / float64(requests.Load()),
		"server_peak_rss_mib": rss / (1024 * 1024),
	})
	if failures.Load() != 0 {
		os.Exit(1)
	}
}
