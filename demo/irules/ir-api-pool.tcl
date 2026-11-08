# ir-api-pool: /api/ to pool-api, everything else to pool-web
when HTTP_REQUEST {
    if { [HTTP::path] starts_with "/api/" } {
        pool pool-api
    } else {
        pool pool-web
    }
}
