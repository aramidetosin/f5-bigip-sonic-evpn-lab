# ir-api-noelse: the same rule without the else (a trap without OneConnect)
when HTTP_REQUEST {
    if { [HTTP::path] starts_with "/api/" } {
        pool pool-api
    }
}
