<!DOCTYPE html>
<html>
<head>
    <title>WebSocket Test</title>
    <script src="https://js.pusher.com/7.0/pusher.min.js"></script>
</head>
<body>
    <h1>WebSocket Dashboard</h1>
    <div id="messages"></div>

    <script>
    const pusher = new Pusher("{{ config('broadcasting.connections.pusher.key') }}", {
        cluster: "{{ config('broadcasting.connections.pusher.options.cluster') }}",
        wsHost: window.location.hostname,
        wsPort: 6001,
        forceTLS: false,
        enabledTransports: ['ws', 'wss'],
    });

        const channel = pusher.subscribe('test-channel');
        channel.bind('test.event', function(data) {
            const messagesDiv = document.getElementById('messages');
            messagesDiv.innerHTML += '<p>' + data.message + '</p>';
        });
    </script>
</body>
</html>
