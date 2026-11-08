# ir-maintenance: /api/ to pool-api; when pool-api has no active member, the BIG-IP answers 503 itself
when HTTP_REQUEST {
    if { [HTTP::path] starts_with "/api/" } {
        if { [active_members pool-api] < 1 } {
            HTTP::respond 503 content "{\"error\":\"maintenance\",\"retry_after\":300}\n" \
                Content-Type "application/json" Retry-After 300
            return
        }
        pool pool-api
    } else {
        pool pool-web
    }
}
