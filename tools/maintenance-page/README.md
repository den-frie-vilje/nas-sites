# maintenance-page

One static page for any site on the NAS while its real stack is down. Every
path on every name answers HTTP 503 with `Retry-After`, so browsers show the
page and search engines keep the site indexed as temporarily unavailable. The
page names the host it was asked for, in Danish or English after the browser's
language (`?lang=da` and `?lang=en` override), in the bureau's own type and
colours, and carries a contact address.

Run it as the operator, like the agent:

```sh
sudo docker compose -p maintenance-page -f /volume1/docker/nas-sites/repo/tools/maintenance-page/compose.yml up -d
```

It listens on `127.0.0.1:18099`. Then, per site to take down, point its DSM
entry at it: a Reverse Proxy rule gets destination `localhost` port 18099; a
Web Station portal gets the `maintenance-page (project)` service. Reverse the
change when the site is back, and `down` the stack.

`GET /ping` answers 200 for health checks.
