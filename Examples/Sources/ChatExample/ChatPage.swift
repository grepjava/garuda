// The page `GET /` serves: join a room, read it over a WebSocket, type into it.

let chatPage = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Garuda chat</title>
<style>
  body { font: 16px/1.4 system-ui, sans-serif; margin: 0 auto; max-width: 40rem; padding: 1rem; }
  #log { border: 1px solid #ccc; height: 60vh; overflow-y: auto; padding: .5rem; }
  .meta { color: #777; font-style: italic; }
  form { display: flex; gap: .5rem; margin-top: .5rem; }
  input[name=text] { flex: 1; }
</style>
</head>
<body>
<h1>Garuda chat</h1>
<form id="join">
  <input name="room" value="lobby" pattern="[a-z0-9-]{1,32}" required>
  <input name="name" placeholder="your name" maxlength="32" required>
  <button>Join</button>
</form>
<div id="log" hidden></div>
<form id="say" hidden>
  <input name="text" maxlength="2000" autocomplete="off" required>
  <button>Send</button>
</form>
<script>
const log = document.getElementById("log");
const join = document.getElementById("join");
const sayForm = document.getElementById("say");
let socket;

function show(message) {
  const line = document.createElement("div");
  const time = new Date(message.at).toLocaleTimeString();
  if (message.kind !== "message") {
    line.className = "meta";
    line.textContent = `${time} ${message.name} ${message.kind}`;
  } else {
    line.textContent = `${time} ${message.name}: ${message.text}`;
  }
  log.append(line);
  log.scrollTop = log.scrollHeight;
}

join.addEventListener("submit", (event) => {
  event.preventDefault();
  const room = join.room.value, name = join.name.value;
  const scheme = location.protocol === "https:" ? "wss" : "ws";
  socket = new WebSocket(`${scheme}://${location.host}/rooms/${room}/ws?name=${encodeURIComponent(name)}`);
  socket.onmessage = (event) => {
    const message = JSON.parse(event.data);
    if (message.missed) { log.append("(some messages were missed)"); return; }
    show(message);
  };
  socket.onclose = () => { log.append("(disconnected)"); sayForm.hidden = true; };
  join.hidden = true;
  log.hidden = false;
  sayForm.hidden = false;
  sayForm.text.focus();
});

sayForm.addEventListener("submit", (event) => {
  event.preventDefault();
  socket.send(sayForm.text.value);
  sayForm.text.value = "";
});
</script>
</body>
</html>
"""
