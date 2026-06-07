const express = require("express");
const http = require("http");
const { Server } = require("socket.io");

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: { origin: "*" }
});

app.use(express.static(__dirname));

let queue = [];

io.on("connection", (socket) => {
  console.log("Someone connected:", socket.id);

  socket.on("joinQueue", (intent) => {
    socket.intent = intent;
    queue.push(socket);
    matchUsers();
  });

  socket.on("sendMessage", (msg) => {
    if (socket.partner) {
      socket.partner.emit("receiveMessage", msg);
    }
  });

  socket.on("skip", (intent) => {
    if (socket.partner) {
      socket.partner.emit("strangerLeft");
      socket.partner.partner = null;
    }
    socket.partner = null;
    socket.intent = intent;
    queue.push(socket);
    matchUsers();
  });

  socket.on("disconnect", () => {
    queue = queue.filter(s => s.id !== socket.id);
    if (socket.partner) {
      socket.partner.emit("strangerLeft");
      socket.partner.partner = null;
    }
  });
});

function matchUsers() {
  while (queue.length >= 2) {
    const user1 = queue.shift();
    const user2 = queue.shift();
    user1.partner = user2;
    user2.partner = user1;
    user1.emit("matched");
    user2.emit("matched");
  }
}

server.listen(process.env.PORT || 3000, () => {
  console.log("Server running on http://localhost:3000");
});