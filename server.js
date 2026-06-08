const express = require('express');
const app = express();
const http = require('http').createServer(app);
const io = require('socket.io')(http);
const path = require('path');

app.use(express.static(__dirname));

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

const queues = { "Just talk": [], "Explore": [], "Keep it light": [], "Something real": [] };

const adaptiveIcebreakers = {
    "Just talk": [
        { text: "What's a minor thing that made your day today?", score: 5, uses: 10 },
        { text: "If your current mood was weather, what would it be?", score: 5, uses: 10 }
    ],
    "Explore": [
        { text: "Give me a random topic you know a lot about.", score: 5, uses: 10 },
        { text: "What's a weird fact that lives rent-free in your head?", score: 5, uses: 10 }
    ],
    "Keep it light": [
        { text: "If you could only eat one meal forever, what is it?", score: 5, uses: 10 },
        { text: "What's your absolute go-to midnight snack?", score: 5, uses: 10 }
    ],
    "Something real": [
        { text: "What is a hard truth about yourself you've accepted?", score: 5, uses: 10 },
        { text: "Are you running towards a goal or taking it day by day?", score: 5, uses: 10 }
    ]
};

const activeRoomsData = {};
const userVibeProfiles = {}; 

io.on('connection', (socket) => {
    
    userVibeProfiles[socket.id] = { avgLength: 0, replySpeed: 0, totalMessagesSent: 0 };

    socket.on('joinQueue', (intent) => {
        if (!queues[intent]) queues[intent] = [];
        if (queues[intent].includes(socket)) return;

        const myProfile = userVibeProfiles[socket.id];
        let matchedPartner = null;
        let matchedIndex = -1;
        const lookForLikeMinded = Math.random() > 0.30; 

        if (queues[intent].length > 0) {
            if (lookForLikeMinded && myProfile.totalMessagesSent > 0) {
                for (let i = 0; i < queues[intent].length; i++) {
                    const candidateProfile = userVibeProfiles[queues[intent][i].id];
                    const lengthDiff = Math.abs(myProfile.avgLength - candidateProfile.avgLength);
                    const speedDiff = Math.abs(myProfile.replySpeed - candidateProfile.replySpeed);
                    
                    if (lengthDiff < 30 && speedDiff < 2000) {
                        matchedPartner = queues[intent][i];
                        matchedIndex = i;
                        break;
                    }
                }
            }

            if (!matchedPartner) matchedPartner = queues[intent].shift();
            else queues[intent].splice(matchedIndex, 1);

            const roomName = `room_${socket.id}_${matchedPartner.id}`;
            socket.join(roomName);
            matchedPartner.join(roomName);

            socket.room = roomName;
            matchedPartner.room = roomName;

            activeRoomsData[roomName] = {
                intent: intent,
                messageCount: 0,
                firstMessage: null,
                isIcebreaker: false,
                timers: {}
            };

            io.to(roomName).emit('matched', roomName);
        } else {
            queues[intent].push(socket);
            socket.currentQueue = intent;
        }
    });

    socket.on('rejoinRoom', (roomName) => {
        socket.join(roomName);
        socket.room = roomName;
        socket.to(roomName).emit('strangerRejoinedRoom');
    });

    socket.on('getIcebreakers', (intent, callback) => {
        const pool = adaptiveIcebreakers[intent] || [];
        const chosen = [...pool]
            .sort((a, b) => (b.score / b.uses) - (a.score / a.uses) + (0.5 - Math.random()))
            .slice(0, 3)
            .map(item => item.text);
        callback(chosen);
    });

    socket.on('sendMessage', (msgObj) => {
        if (socket.room) {
            const roomData = activeRoomsData[socket.room];
            if (roomData) {
                roomData.messageCount++;
                const profile = userVibeProfiles[socket.id];
                if (profile) {
                    profile.totalMessagesSent++;
                    profile.avgLength = Math.round(((profile.avgLength * (profile.totalMessagesSent - 1)) + msgObj.text.length) / profile.totalMessagesSent);
                }
                if (roomData.messageCount === 1) {
                    roomData.firstMessage = msgObj.text;
                    const poolTexts = adaptiveIcebreakers[roomData.intent].map(i => i.text);
                    roomData.isIcebreaker = poolTexts.includes(msgObj.text);
                }
            }
            socket.to(socket.room).emit('receiveMessage', msgObj);
            socket.to(socket.room).emit('firstMessageSent');
        }
    });

    socket.on('editMessage', (editPayload) => {
        if (socket.room) socket.to(socket.room).emit('strangerEditedMessage', editPayload);
    });

    socket.on('deleteMessage', (msgId) => {
        if (socket.room) socket.to(socket.room).emit('strangerDeletedMessage', msgId);
    });

    socket.on('typing', (isTyping) => {
        if (socket.room) socket.to(socket.room).emit('strangerTyping', isTyping);
    });

    function evaluateRoomMetrics(roomName) {
        const data = activeRoomsData[roomName];
        if (!data || !data.firstMessage) return;
        const pool = adaptiveIcebreakers[data.intent];

        if (data.isIcebreaker) {
            const index = pool.findIndex(i => i.text === data.firstMessage);
            if (index !== -1) {
                pool[index].uses++;
                if (data.messageCount >= 4) { pool[index].score += 2; }
            }
        } else {
            if (data.firstMessage.length > 10 && data.firstMessage.length < 120 && data.messageCount >= 4) {
                const alreadyExists = pool.some(i => i.text === data.firstMessage);
                if (!alreadyExists) {
                    pool.push({ text: data.firstMessage, score: 3, uses: 1 });
                }
            }
        }
        delete activeRoomsData[roomName];
    }

    socket.on('skip', (intent) => {
        if (socket.room) {
            const activeRoom = socket.room;
            evaluateRoomMetrics(activeRoom);
            socket.to(activeRoom).emit('strangerLeft');
            io.in(activeRoom).socketsLeave(activeRoom);
        }
        if (socket.currentQueue && queues[socket.currentQueue]) {
            queues[socket.currentQueue] = queues[socket.currentQueue].filter(s => s.id !== socket.id);
        }
        socket.emit('requeue', intent);
    });

    socket.on('disconnecting', () => {
        if (socket.room) {
            const activeRoom = socket.room;
            evaluateRoomMetrics(activeRoom);
            socket.to(activeRoom).emit('strangerLeft');
            io.in(activeRoom).socketsLeave(activeRoom);
        }
        if (socket.currentQueue && queues[socket.currentQueue]) {
            queues[socket.currentQueue] = queues[socket.currentQueue].filter(s => s.id !== socket.id);
        }
        delete userVibeProfiles[socket.id];
    });

    socket.on('disconnect', () => {});
});

const PORT = process.env.PORT || 3000;
http.listen(PORT, "0.0.0.0", () => {
    console.log(`StrangerTalks live engine operating on port ${PORT}`);
});