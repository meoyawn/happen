# Desktop responsiveness

- No I/O on the main Flutter isolate. Workers own filesystem, database, network,
  and subprocess effects, including opening and closing their resources. The UI
  dispatches requests and consumes results.
- `async` and `await` do not make I/O safe on the UI isolate. Native setup in
  APIs such as `Process.start` can block before their futures complete.
- Pass caller cancellation to worker effects, cancel superseded work, and ignore
  stale completions. Keep resource handles with their worker owner.
- Thread navigation must not wait for I/O or rebuild unchanged workspace views.
  Keep the selected sidebar card visible, support held Option–Up/Down, and verify
  input-to-render latency with Dart MCP against the running app.
- Probe widgets offscreen. Never drive the human's visible app automatically.
