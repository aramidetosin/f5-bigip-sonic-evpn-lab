# ir-https-redirect: every HTTP request answered by the BIG-IP with a permanent redirect to the same URL over HTTPS
when HTTP_REQUEST {
    HTTP::respond 301 Location "https://[getfield [HTTP::host] ":" 1][HTTP::uri]" Connection close
}
