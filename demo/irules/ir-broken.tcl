# ir-broken: a runtime error on purpose: without an X-Api-Version header, expr gets an empty string
when HTTP_REQUEST {
    set version [expr {[HTTP::header value X-Api-Version] + 1}]
    HTTP::header insert X-Next-Version $version
}
