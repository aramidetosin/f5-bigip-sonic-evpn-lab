# ir-headers: add two request headers for the server, add one response header for the client, remove one
when HTTP_REQUEST {
    HTTP::header insert X-Forwarded-Proto "http"
    HTTP::header insert X-Client-Port [TCP::client_port]
}
when HTTP_RESPONSE {
    HTTP::header insert X-Pool-Member [LB::server addr]
    HTTP::header remove X-Server
}
