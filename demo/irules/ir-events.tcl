# ir-events: log every event of one request, in the order TMM runs them
when CLIENT_ACCEPTED {
    log local0. "[IP::client_addr]:[TCP::client_port] to [IP::local_addr]:[TCP::local_port]"
}
when HTTP_REQUEST {
    log local0. "[HTTP::method] [HTTP::host][HTTP::uri]"
}
when LB_SELECTED {
    log local0. "pool member [LB::server addr]:[LB::server port]"
}
when SERVER_CONNECTED {
    log local0. "[IP::local_addr]:[TCP::local_port] to [IP::server_addr]:[TCP::server_port]"
}
when HTTP_RESPONSE {
    log local0. "status [HTTP::status]"
}
when CLIENT_CLOSED {
    log local0. "client connection closed"
}
