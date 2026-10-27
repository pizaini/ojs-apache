# Shared directives for cacheable OJS locations — include inside a location {}
# that already sets proxy_pass and proxy_cache_valid.
#
# Exposed as a snippet so every journal server block stays identical and there
# is exactly one place to change cache behaviour.

proxy_cache               $ojs_cache_zone;
# $host keeps the tenants apart; $request_uri keeps locale/query variants
# apart. Never drop $host here.
proxy_cache_key           "$host$request_uri";
proxy_cache_lock          on;
proxy_cache_use_stale     updating error timeout;
proxy_cache_background_update on;

# Laravel's StartSession adds "Cache-Control: no-cache, private" and a
# "Set-Cookie: OJSSID=..." header to every response. Both must be ignored for
# anonymous pages, otherwise nothing is ever cacheable.
proxy_ignore_headers      Cache-Control Expires Set-Cookie;
# Hide the session cookie from cached responses: serving one OJSSID to every
# visitor would mean shared sessions.
proxy_hide_header         Set-Cookie;

proxy_cache_bypass        $ojs_bypass $ojs_refresh;
proxy_no_cache            $ojs_bypass;

add_header X-Cache-Status $upstream_cache_status always;
add_header Strict-Transport-Security "max-age=31536000" always;