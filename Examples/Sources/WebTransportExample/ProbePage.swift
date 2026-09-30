// The page that runs the probe from a browser, with the browser's own
// WebTransport API. The page must come over HTTPS for the API to exist, and
// a self-signed certificate is trusted for WebTransport only through
// `serverCertificateHashes` -- which is why the server publishes its hash.

let probePage = #"""
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>WebTransport probe</title>
<style>
body{font:15px/1.6 system-ui,sans-serif;margin:2rem;max-width:44rem}
pre{background:#f4f4f5;padding:.75rem 1rem;overflow-x:auto;border-radius:6px;min-height:8rem}
button{font:inherit;padding:.3rem .9rem}
</style>
<h1>WebTransport probe</h1>
<p>Round trips on datagrams, then a download and an upload on streams, all in
one session over HTTP/3.</p>
<p><button id="run">Run the probe</button></p>
<pre id="out"></pre>
<script type="module">
const out = document.getElementById("out");
const say = (line) => { out.textContent += line + "\n"; };

function bytesOf(hex) {
  return new Uint8Array(hex.match(/../g).map((h) => parseInt(h, 16)));
}

async function readAll(readable) {
  const reader = readable.getReader();
  const chunks = [];
  let total = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    chunks.push(value);
    total += value.length;
  }
  const all = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) { all.set(c, at); at += c.length; }
  return all;
}

async function command(transport, line, body) {
  const stream = await transport.createBidirectionalStream();
  const writer = stream.writable.getWriter();
  const started = performance.now();
  await writer.write(new TextEncoder().encode(line + "\n"));
  if (body) await writer.write(body);
  await writer.close();
  const answer = await readAll(stream.readable);
  return { answer, ms: performance.now() - started };
}

async function probe() {
  out.textContent = "";
  if (!("WebTransport" in window)) { say("This browser has no WebTransport."); return; }

  const options = {};
  const hash = await fetch("/certificate-hash");
  if (hash.ok) {
    const { sha256 } = await hash.json();
    options.serverCertificateHashes = [{ algorithm: "sha-256", value: bytesOf(sha256) }];
  }
  const transport = new WebTransport(`https://${location.host}/probe?name=browser`, options);
  await transport.ready;

  // The greeting, on the stream the server opens first.
  const incoming = transport.incomingUnidirectionalStreams.getReader();
  const { value: first } = await incoming.read();
  const greeting = JSON.parse(new TextDecoder().decode(await readAll(first)));
  say(`session ${greeting.session}, datagrams up to ${greeting.maxDatagramSize} bytes`);

  // Round trips: a datagram carrying its number, timed until it comes back.
  const send = transport.datagrams.writable.getWriter();
  const receive = transport.datagrams.readable.getReader();
  const times = [];
  for (let i = 0; i < 20; i++) {
    const started = performance.now();
    await send.write(new Uint8Array([i]));
    const back = await Promise.race([
      receive.read(),
      new Promise((resolve) => setTimeout(() => resolve(null), 1000)),
    ]);
    if (back) times.push(performance.now() - started);
  }
  times.sort((a, b) => a - b);
  say(`round trip: ${times.length}/20 came back, median ${times[times.length >> 1]?.toFixed(2)} ms`);

  const size = 16 << 20;
  const down = await command(transport, `download ${size}`);
  say(`download: ${down.answer.length} bytes, ${(size * 8 / down.ms / 1000).toFixed(0)} Mbit/s`);

  const up = await command(transport, "upload", new Uint8Array(size));
  const told = JSON.parse(new TextDecoder().decode(up.answer));
  say(`upload: the server read ${told.bytes} bytes, ${(size * 8 / up.ms / 1000).toFixed(0)} Mbit/s`);

  transport.close({ closeCode: 0, reason: "done" });
}

document.getElementById("run").onclick = () => probe().catch((e) => say("failed: " + e));
</script>
"""#
